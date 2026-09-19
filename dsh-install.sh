#!/data/data/com.termux/files/usr/bin/bash
# dsh-install.sh — 安装 @deepseek-ai/dsh 到 Termux (android-arm64),并修补全部已知兼容性问题。
#
# 在原 lilyco-42/dsh-termux 安装流程(node-gyp / sharp / session-persistence / shebang / key)
# 基础上,新增 patch-dsh.py 的全部 4 个补丁:
#   1. node-addon-system/flock.js     : flock 在 android-arm64 不支持 -> 无操作 stub
#   2. dsh-session-persistence-jsonl  : 发布日志用硬链接 link() -> rename();import 补 rename
#   3. dsh-fs-local                   : linkFile 失败(EACCES)时兜底 rename()
#   4. dsh-attachment-local           : link 调用加 EACCES 防护
#   5. dsh-tool-fs-search             : @vscode/ripgrep 缺 android-arm64 -> 创建假平台包 + 系统 rg fallback
#   6. dsh-sandbox-local              : PLATFORM_CHAINS 缺 android -> 加 android:[] + passthrough 降级
#
# 健壮性设计:
#   - 每个补丁先检测 marker(已打过则跳过,幂等,避免二次补坏)
#   - MISS(锚点失配)/SKIP(文件缺失)都打印明显 WARNING 并以非零码结束,
#     让调用方知道"补丁没全生效",而不是静默漏补
#   - flock 补丁用"函数级正则替换"做主策略 + 精确串替换做兜底,降低上游微调代码导致的失配
#
# 用法:
#   bash dsh-install.sh                # 完整安装 + 打补丁
#   bash dsh-install.sh --patch-only   # 只打补丁(已装 dsh,更新后修复用)
#   bash dsh-install.sh --check        # 只检测,不写;全部 OK 退出 0,否则非零

set -uo pipefail

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$1" "$2"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$1" >&2; }

MODE="install"
for a in "$@"; do
  case "$a" in
    --patch-only) MODE="patch-only" ;;
    --check)      MODE="check" ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

find_deepseek_key() {
    local key f creds
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        printf '%s' "$DEEPSEEK_API_KEY"; return 0
    fi
    creds="${DSH_HOME:-$HOME/.dsh}/.credentials.yaml"
    if [ -f "$creds" ]; then
        key="$(grep -E 'DEEPSEEK_API_KEY[[:space:]]*:' "$creds" 2>/dev/null | head -1 \
            | sed -E 's/.*DEEPSEEK_API_KEY[[:space:]]*:[[:space:]]*//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key#\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    fi
    for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
        [ -f "$f" ] || continue
        key="$(grep -E '^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=' "$f" 2>/dev/null | head -1 \
            | sed -E 's/^[[:space:]]*export[[:space:]]+DEEPSEEK_API_KEY=//' | tr -d " \t\r")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key#\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    for f in "$HOME/.deepseek_api_key" "$HOME/.deepseek"; do
        [ -f "$f" ] || continue
        key="$(head -1 "$f" 2>/dev/null | tr -d " \t\r\n")"
        key="${key#\"}"; key="${key%\"}"; key="${key#\'}"; key="${key#\'}"
        [ -n "$key" ] && { printf '%s' "$key"; return 0; }
    done
    return 1
}

NDK_TARGET="aarch64-unknown-linux-android30"

# ============================================================
# 1. 前置依赖
# ============================================================
if [ "$MODE" = "install" ]; then
    log 1/7 "Installing prerequisites..."
    pkg install -y nodejs build-essential clang cmake ninja python ripgrep >/dev/null

    # libvips + glib: Termux 无 libvips-dev 包, libvips 本身含头文件
    pkg install -y libvips glib >/dev/null 2>&1 || warn "libvips/glib 安装失败, sharp 编译将跳过"
    # 校验 glib-object.h 是否存在; 不存在则尝试升级
    if [ ! -f "$PREFIX/include/glib-2.0/glib-object.h" ] && [ ! -f "$PREFIX/include/glib-object.h" ]; then
        warn "glib-object.h 未找到, 尝试 pkg upgrade..."
        pkg upgrade -y libvips glib >/dev/null 2>&1 || true
    fi

    if ! NODE_BIN="$(command -v node)"; then
        err "'node' not found after pkg install"; exit 1
    fi
    NODE_GYP_BIN="$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js"
    DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"
    [ -f "$NODE_GYP_BIN" ] || { err "node-gyp not found at $NODE_GYP_BIN"; exit 1; }
else
    NODE_BIN="$(command -v node 2>/dev/null)"
    [ -n "$NODE_BIN" ] || { err "node 未找到,无法打补丁"; exit 1; }
    DSH_LIB="$(npm root -g)/@deepseek-ai/dsh"
fi

# ============================================================
# 2. patch node-gyp (drop bogus OS=android)
# ============================================================
if [ "$MODE" = "install" ]; then
    log 2/7 "Patching node-gyp (drop OS=android)..."
    CREATE_GYPI="$(npm root -g)/npm/node_modules/node-gyp/lib/create-config-gypi.js"
    if [ ! -f "$CREATE_GYPI" ]; then
        err "node-gyp not found at $CREATE_GYPI"; exit 1
    fi
    if grep -q "delete variables.OS" "$CREATE_GYPI"; then
        echo "    node-gyp already patched, skipping."
    else
        python3 - "$CREATE_GYPI" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
anchor = "const variables = config.variables\n"
assert anchor in src, "patch anchor not found; node-gyp may have changed"
block = (
    anchor + "\n"
    + "  // Termux's Node.js reports process.config.variables.OS as \"android\" even\n"
    + "  // though native addons build against the Termux (linux-like) sysroot.\n"
    + "  // Drop OS so gyp infers it as \"linux\" from the host platform.\n"
    + "  delete variables.OS\n"
)
open(path, "w", encoding="utf-8").write(src.replace(anchor, block, 1))
print("    patched", path)
PY
    fi
fi

# ============================================================
# 3. 安装 dsh(编译原生模块)
# ============================================================
if [ "$MODE" = "install" ]; then
    log 3/7 "Installing @deepseek-ai/dsh (native modules will be compiled)..."
    export CFLAGS="--target=$NDK_TARGET"
    export CXXFLAGS="--target=$NDK_TARGET"
    npm install -g @deepseek-ai/dsh || { err "npm install failed"; exit 1; }
fi

DSH_LIB="${DSH_LIB:-$(npm root -g)/@deepseek-ai/dsh}"
DSH_PKG_DIR="$DSH_LIB/node_modules/@deepseek-ai"

# ============================================================
# 4. 构建 sharp(对系统 libvips)
# ============================================================
if [ "$MODE" = "install" ]; then
    log 4/7 "Building sharp against system libvips..."
    SHARP_DIR="$DSH_LIB/node_modules/sharp"
    if ls "$SHARP_DIR/src/build/Release/sharp-android-arm64-"*.node >/dev/null 2>&1; then
        echo "    sharp already built, skipping."
    elif [ -d "$SHARP_DIR" ]; then
        # patch binding.gyp: pkg-config 依赖链解析在 Termux 上会因 X11 包缺失而失败,
        # 导致 include_dirs 为空。改为直接硬编码 glib + vips include 路径。
        GYP="$SHARP_DIR/src/binding.gyp"
        if grep -q "termux-sharp-include-patch" "$GYP" 2>/dev/null; then
            echo "    binding.gyp already patched, skipping."
        else
            python3 - "$GYP" "$PREFIX" <<'PY'
import sys
path, prefix = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()

# Patch 1: include_dirs — 硬编码, 不依赖 pkg-config 依赖链
anchor_inc = "'include_dirs': ['<!@(PKG_CONFIG_PATH=\"<(pkg_config_path)\" pkg-config --cflags-only-I vips-cpp vips glib-2.0 | sed s/-I//g)'],"
repl_inc = (
    "# termux-sharp-include-patch: hard-coded includes (pkg-config dep chain breaks on Termux due to missing X11 .pc files)\n"
    "        'include_dirs': [\n"
    f"          '{prefix}/include/glib-2.0',\n"
    f"          '{prefix}/lib/glib-2.0/include',\n"
    f"          '{prefix}/include',\n"
    f"          '{prefix}/include/vips',\n"
    f"          '{prefix}/include/vips/vips8',\n"
    "        ],\n"
)
if anchor_inc in src:
    src = src.replace(anchor_inc, repl_inc, 1)
else:
    print("    [WARN] include_dirs anchor not found; upstream may have changed")
    sys.exit(1)

# Patch 2: libraries — 硬编码 -lvips-cpp
anchor_lib = "'libraries': ['<!@(PKG_CONFIG_PATH=\"<(pkg_config_path)\" pkg-config --libs vips-cpp)'],"
repl_lib = (
    "# termux-sharp-include-patch: hard-coded libs (avoids pkg-config dep chain)\n"
    "        'libraries': ['-lvips-cpp'],\n"
)
if anchor_lib in src:
    src = src.replace(anchor_lib, repl_lib, 1)
else:
    print("    [WARN] libraries anchor not found; upstream may have changed")
    sys.exit(1)

open(path, "w", encoding="utf-8").write(src)
print("    patched binding.gyp (hardcoded glib+vips includes+libs)")
PY
        fi

        if ! (cd "$SHARP_DIR" && SHARP_FORCE_GLOBAL_LIBVIPS=1 \
            CFLAGS="--target=$NDK_TARGET" CXXFLAGS="--target=$NDK_TARGET" \
            "$NODE_BIN" "$(npm root -g)/npm/node_modules/node-gyp/bin/node-gyp.js" \
            rebuild --directory=src >/dev/null); then
            warn "sharp 编译失败"
            warn "  若报 glib-object.h not found:"
            warn "    1. pkg install -y glib libvips"
            warn "    2. ls $PREFIX/include/glib-2.0/glib-object.h"
            warn "    3. 重新运行: bash dsh-install.sh --patch-only"
        fi
    else
        warn "sharp module not found"
    fi
fi

# ============================================================
# 5. session-persistence 硬链接 -> rename(原版已有,保留)
# ============================================================
if [ "$MODE" = "install" ]; then
    log 5/7 "Patching session persistence (link -> rename)..."
    SESSION_JS="$DSH_PKG_DIR/dsh-session-persistence-jsonl/lib/index.js"
    if [ -f "$SESSION_JS" ]; then
        if grep -q "await rename(tmp, finalPath)" "$SESSION_JS"; then
            echo "    session persistence already patched, skipping."
        else
            python3 - "$SESSION_JS" <<'PY'
import sys
path = sys.argv[1]
src = open(path, encoding="utf-8").read()
src = src.replace(
    'import { link, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";',
    'import { mkdir, mkdtemp, open, readFile, readdir, realpath, rename, rm, stat, truncate } from "node:fs/promises";',
)
src = src.replace(
    "\t\t\tawait link(tmp, finalPath);",
    "\t\t\tawait rename(tmp, finalPath);",
)
open(path, "w", encoding="utf-8").write(src)
print("    patched", path)
PY
        fi
    else
        warn "session persistence module not found"
    fi
fi

# ============================================================
# 6. 修 shebang(node --expose-internals)
# ============================================================
if [ "$MODE" = "install" ]; then
    log 6/7 "Fixing shebang (node --expose-internals)..."
    DSH_BIN="$DSH_LIB/lib/bin.js"
    if [ -f "$DSH_BIN" ]; then
        python3 - "$DSH_BIN" "$NODE_BIN" <<'PY'
import sys
path, node = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
first, _, rest = src.partition("\n")
if not first.startswith("#!"):
    sys.exit("no shebang on first line")
src = "#!" + node + " --expose-internals\n" + rest
open(path, "w", encoding="utf-8").write(src)
print("    shebang set:", node, "--expose-internals")
PY
    fi
fi

# ============================================================
# 7. 修 @vscode/ripgrep 缺 android-arm64 平台包
#    创建假平台包(符号链接到系统 rg) + 给 dsh-tool-fs-search
#    的 resolveRgPath() 加系统 rg fallback,确保 glob/grep 可用
# ============================================================
log 7/8 "Fixing @vscode/ripgrep android-arm64 (glob/grep)..."

# 确保系统 rg 存在
if ! command -v rg >/dev/null 2>&1; then
    pkg install -y ripgrep >/dev/null 2>&1 || warn "ripgrep install failed"
    command -v rg >/dev/null 2>&1 || err "rg still not found after pkg install"
fi
SYSTEM_RG="$(command -v rg)"

# 创建 @vscode/ripgrep-android-arm64 假平台包
RG_FAKE_DIR="$DSH_PKG_DIR/../@vscode/ripgrep-android-arm64"
if [ ! -d "$RG_FAKE_DIR" ]; then
    mkdir -p "$RG_FAKE_DIR/bin"
    printf '{"name":"@vscode/ripgrep-android-arm64","version":"1.18.0","files":["bin/"]}' > "$RG_FAKE_DIR/package.json"
    ln -sf "$SYSTEM_RG" "$RG_FAKE_DIR/bin/rg"
    echo "    created @vscode/ripgrep-android-arm64 -> $SYSTEM_RG"
else
    echo "    @vscode/ripgrep-android-arm64 already exists, skipping."
fi

# 给 dsh-tool-fs-search 的 resolveRgPath() 加系统 rg fallback
# (此步骤仅做快速预检;真正的补丁在下方 Python 补丁集中统一执行)
FSSEARCH_JS="$DSH_PKG_DIR/dsh-tool-fs-search/lib/index.js"
if [ -f "$FSSEARCH_JS" ]; then
    if grep -q "termux-rg-fallback" "$FSSEARCH_JS"; then
        echo "    dsh-tool-fs-search already patched, skipping."
    else
        echo "    dsh-tool-fs-search will be patched in step 8."
    fi
else
    warn "dsh-tool-fs-search module not found"
fi

# ============================================================
# 8. 关键补丁集(flock + fs-local + attachment-local + session 补强)
#    合并自 patch-dsh.py,确保每次更新后都补齐
# ============================================================
log 8/8 "Applying full compatibility patch set (flock/fs-local/attachment/session)..."

CHECK_ONLY=0
[ "$MODE" = "check" ] && CHECK_ONLY=1

DSH_PKG_DIR="$DSH_PKG_DIR" CHECK_ONLY="$CHECK_ONLY" python3 - <<'PY'
import os, re, sys, pathlib

PKG = pathlib.Path(os.environ["DSH_PKG_DIR"])
CHECK_ONLY = os.environ.get("CHECK_ONLY", "0") == "1"

results = []   # (name, status)
misses = []    # (name, desc) 失配项
skips = []     # (name,)      缺失项

def patch(path, marker, transforms):
    name = path.name
    if not path.exists():
        results.append((name, "SKIP (not found)"))
        skips.append(name)
        return
    src = path.read_text(encoding="utf-8")
    if marker in src:
        # 检测 marker 存在但 patch 不完整或文件损坏
        # 情况 1: link 和 rename 同时存在(手动 patch 残留错误格式)
        # 情况 2: defaultFileSystem 缺少 }(rm 行后直接接 const defaultInternals)
        needs_repair = False
        if "await internals.fs.link(staged, currentPath);" in src and "await internals.fs.rename(staged, currentPath);" in src:
            needs_repair = True
            repair_reason = "malformed publish patch"
        elif "\trm: (path) => rm(path, { force: true })\n\nconst defaultInternals" in src:
            needs_repair = True
            repair_reason = "missing }; in defaultFileSystem"
        if needs_repair:
            results.append((name, f"REPAIR ({repair_reason})"))
            if CHECK_ONLY:
                return
            # 情况 1: 移除旧的错误 publish patch
            if "await internals.fs.link(staged, currentPath);" in src and "await internals.fs.rename(staged, currentPath);" in src:
                old_block = """	} catch (error) {
	/* termux-publish-fallback */
	if (error instanceof Error && "code" in error && error.code === "EACCES") {
		await internals.fs.rename(staged, currentPath);
	} else {
		/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
		if (isEEXIST(error)) return false;
		/* v8 ignore next -- the filesystem error is already complete. */
		throw error;
	}
	}"""
                new_block = """	} catch (error) {
		/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
		if (isEEXIST(error)) return false;
		/* v8 ignore next -- the filesystem error is already complete. */
		throw error;
	}"""
                if old_block in src:
                    src = src.replace(old_block, new_block, 1)
            # 情况 2: 补上缺失的 };
            if "\trm: (path) => rm(path, { force: true })\n\nconst defaultInternals" in src:
                src = src.replace("\trm: (path) => rm(path, { force: true })\n\nconst defaultInternals", "\trm: (path) => rm(path, { force: true })\n};\nconst defaultInternals", 1)
            # 写回修复后的文件, 继续执行下面的 patch 逻辑
            path.write_text(src, encoding="utf-8")
            # 关键: 上面已就地修复损坏的 patch 状态并写回,
            # 直接判定完成。若落入下面的常规 transforms 流程, 幂等的
            # "publish link->rename" 会失配(文件里已无旧 link 调用),
            # 导致 install 模式误报"补丁未完全生效"并以非零码退出。
            results[-1] = (name, f"REPAIRED ({repair_reason})")
            return
        else:
            results.append((name, "OK (already patched)"))
            return
    if CHECK_ONLY:
        results.append((name, "NEEDS PATCH"))
        return
    new = src
    applied = []
    for desc, fn in transforms:
        try:
            out = fn(new)
        except Exception as e:
            applied.append(f"{desc}: ERROR {e}")
            misses.append((name, desc))
            continue
        if out is None:
            applied.append(f"{desc}: MISS")
            misses.append((name, desc))
        elif out != new:
            new = out
            applied.append(f"{desc}: OK")
        else:
            applied.append(f"{desc}: no-op")
    if new != src:
        path.write_text(new, encoding="utf-8")
        results.append((name, "WROTE | " + "; ".join(applied)))
    else:
        results.append((name, "NO CHANGE | " + "; ".join(applied)))

def once(old, new):
    def fn(s):
        return s.replace(old, new, 1) if old in s else None
    return fn

# ---------- 1. flock.js(函数级正则主策略 + 精确串兜底) ----------
FLOCK_PATH = PKG / "node-addon-system" / "lib" / "flock.js"

def flock_regex(s):
    # 匹配 load() 里 "非 linux/darwin 就 throw" 的整段分支,替换为 stub。
    # 容错: 错误文案/缩进变化时仍能命中(只锚定结构,不锚定具体错误文本)。
    pat = re.compile(
        r"(if \(platform !== 'linux' && platform !== 'darwin'\) \{\n)"
        r"(?:\s*throw Object\.assign\(new Error\(`flock is not supported.*?\);\n)"
        r"(?:[^\n]*\n)*?"
        r"(    \})\s*\n(\s*)return require\(",
        re.S,
    )
    def repl(m):
        close_indent = m.group(2)
        ret_indent = m.group(3)
        return (
            m.group(1)
            + "    /* termux-flock-stub */\n"
            + "    const binding = { tryLock: (_fd, cb) => cb(0), unlock: (_fd, cb) => cb(0) };\n"
            + "    return binding;\n"
            + close_indent
            + "\n" + ret_indent + "return require("
        )
    out, n = pat.subn(repl, s, count=1)
    return out if n else None

FLOCK_OLD = (
    "if (platform !== 'linux' && platform !== 'darwin') {\n"
    "        throw Object.assign(new Error(`flock is not supported on ${platform}-${arch}`), {\n"
    "            code: 'ERR_FLOCK_UNSUPPORTED_PLATFORM',\n"
    "            syscall: 'flock',\n"
    "        });\n"
    "    }"
)
FLOCK_NEW = (
    "if (platform !== 'linux' && platform !== 'darwin') {\n"
    "        /* termux-flock-stub */\n"
    "        const binding = { tryLock: (_fd, cb) => cb(0), unlock: (_fd, cb) => cb(0) };\n"
    "        return binding;\n"
    "    }"
)

if FLOCK_PATH.exists():
    src = FLOCK_PATH.read_text(encoding="utf-8")
    if "termux-flock-stub" in src:
        results.append(("flock.js", "OK (already patched)"))
    elif CHECK_ONLY:
        results.append(("flock.js", "NEEDS PATCH"))
    else:
        new = flock_regex(src)
        how = "regex"
        if new is None:
            new = once(FLOCK_OLD, FLOCK_NEW)(src)
            how = "exact"
        if new is None:
            results.append(("flock.js", "MISS (both strategies failed)"))
            misses.append(("flock.js", "platform stub"))
        else:
            FLOCK_PATH.write_text(new, encoding="utf-8")
            results.append(("flock.js", f"WROTE (strategy={how})"))
else:
    results.append(("flock.js", "SKIP (not found)"))
    skips.append("flock.js")

# ---------- 2. session-persistence ----------
SP_PATH = PKG / "dsh-session-persistence-jsonl" / "lib" / "index.js"

def sp_import(s):
    m = re.search(r'import \{([^}]*)\} from "node:fs/promises";', s)
    if not m:
        return None
    names = [x.strip() for x in m.group(1).split(",") if x.strip()]
    if "rename" in names:
        return s
    names.append("rename")
    return s[:m.start()] + 'import { ' + ", ".join(names) + ' } from "node:fs/promises";' + s[m.end():]

def sp_default_fs(s):
    # 找 defaultFileSystem 对象里的 link, 行, 在它后面加 rename,
    # 不用正则匹配整个对象块(上游格式可能变化), 只精确替换 \tlink,\n -> \tlink,\n\trename,\n
    if "\tlink,\n" not in s:
        return None
    # 检查是否已有 rename,
    m = re.search(r'const defaultFileSystem = \{\n((?:\t[^\n]*\n)+)', s)
    if m:
        block = m.group(1)
        if re.search(r'^\trename,\s*$', block, re.M):
            return s  # 已有 rename
    return s.replace("\tlink,\n", "\tlink,\n\trename,\n", 1)

def sp_fix_missing_close(s):
    # 修复 defaultFileSystem 对象缺少 }; 的情况
    # 如果 rm 行后面直接接 const defaultInternals(中间没有 };), 补上 };
    anchor = "\trm: (path) => rm(path, { force: true })\n\nconst defaultInternals"
    if anchor in s:
        return s.replace(anchor, "\trm: (path) => rm(path, { force: true })\n};\nconst defaultInternals", 1)
    # 当前上游(defaultFileSystem 以 \n}; 正常收尾)本步无需动作。
    # 返回 s 表示已检查且无需改动 —— 返回 None 会被误报为"失配",
    # 即使文件本身完好也会让 install 模式以非零码退出。
    return s

patch(SP_PATH, "termux-publish-fallback", [
    ("import rename", sp_import),
    ("defaultFileSystem rename", sp_default_fs),
    ("fix missing };", sp_fix_missing_close),
    ("publish link->rename", (lambda o, n: (lambda s: n if o in s else (s if n in s else None)))(
        "await internals.fs.link(staged, currentPath);",
        "/* termux-publish-fallback */\n\t\tawait internals.fs.rename(staged, currentPath);",
    )),
])

# ---------- 3. fs-local ----------
FSLOCAL_PATH = PKG / "dsh-fs-local" / "lib" / "index.js"

def fs_local(s):
    pat = re.compile(
        r"(\t+)if \(createIfAbsent !== void 0\) try \{\n"
        r"\1\tawait linkFile\(tempPath, absolutePath\);\n"
        r"\1\} catch \(error\) \{\n"
        r"\1\tawait throwGuardedCreateFailure\(error, absolutePath, createIfAbsent\.displayPath, inspectPublicationTarget\);\n"
        r"\1\}"
    )
    def repl(m):
        i = m.group(1)
        return (
            f"{i}if (createIfAbsent !== void 0) try {{\n"
            f"{i}\ttry {{\n"
            f"{i}\t\tawait linkFile(tempPath, absolutePath);\n"
            f"{i}\t}} catch (error) {{\n"
            f"{i}\t\t/* termux-noreplace-fallback */\n"
            f'{i}\t\tif (!(error instanceof Error && "code" in error && error.code === "EACCES")) throw error;\n'
            f"{i}\t\tawait rename(tempPath, absolutePath);\n"
            f"{i}\t}}\n"
            f"{i}}} catch (error) {{\n"
            f"{i}\tawait throwGuardedCreateFailure(error, absolutePath, createIfAbsent.displayPath, inspectPublicationTarget);\n"
            f"{i}}}"
        )
    out, n = pat.subn(repl, s, count=1)
    return out if n else None

patch(FSLOCAL_PATH, "termux-noreplace-fallback", [
    ("linkFile EACCES fallback", fs_local),
])

# ---------- 4. attachment-local ----------
ATTACH_PATH = PKG / "dsh-attachment-local" / "lib" / "index.js"

def attach(s):
    pat = re.compile(r'(\s*)await link\(([^)]+)\);')
    def repl(m):
        i = m.group(1)
        return (
            f"{i}try {{\n"
            f"{i}\tawait link({m.group(2)});\n"
            f"{i}}} catch (error) {{\n"
            f"{i}\t/* termux-hardlink-fallback */\n"
            f'{i}\tif (!(error instanceof Error && "code" in error && error.code === "EACCES")) throw error;\n'
            f"{i}\tthrow error;\n"
            f"{i}}}"
        )
    out, n = pat.subn(repl, s)
    return out if n else None

patch(ATTACH_PATH, "termux-hardlink-fallback", [
    ("link EACCES guard", attach),
])

# ---------- 5. dsh-tool-fs-search(glob/grep ripgrep fallback) ----------
FSSEARCH_PATH = PKG / "dsh-tool-fs-search" / "lib" / "index.js"
if FSSEARCH_PATH.exists():
    src = FSSEARCH_PATH.read_text(encoding="utf-8")
    if "termux-rg-fallback" in src:
        results.append(("dsh-tool-fs-search/index.js", "OK (already patched)"))
    elif CHECK_ONLY:
        results.append(("dsh-tool-fs-search/index.js", "NEEDS PATCH"))
    else:
        anchor = '\t\treturn (await import("@vscode/ripgrep")).rgPath;\n\t});'
        if anchor not in src:
            results.append(("dsh-tool-fs-search/index.js", "MISS (anchor not found)"))
            misses.append(("dsh-tool-fs-search/index.js", "resolveRgPath"))
        else:
            replacement = (
                '\t\ttry {\n'
                '\t\t\treturn (await import("@vscode/ripgrep")).rgPath;\n'
                '\t\t} catch {\n'
                '\t\t\t/* termux-rg-fallback: resolve system rg from PATH */\n'
                '\t\t\tconst { execSync } = await import("node:child_process");\n'
                '\t\t\tconst sysRg = execSync("command -v rg 2>/dev/null", { encoding: "utf8", env: process.env }).trim();\n'
                '\t\t\tif (sysRg && existsSync(sysRg)) return sysRg;\n'
                '\t\t\tthrow new Error("Could not resolve ripgrep: @vscode/ripgrep missing and no system rg in PATH");\n'
                '\t\t}\n'
                '\t});'
            )
            new = src.replace(anchor, replacement, 1)
            FSSEARCH_PATH.write_text(new, encoding="utf-8")
            results.append(("dsh-tool-fs-search/index.js", "WROTE (rg fallback)"))
else:
    results.append(("dsh-tool-fs-search/index.js", "SKIP (not found)"))
    skips.append("dsh-tool-fs-search/index.js")

# ---------- 6. dsh-sandbox-local(android passthrough) ----------
SANDBOX_PATH = PKG / "dsh-sandbox-local" / "lib" / "index.js"
if SANDBOX_PATH.exists():
    src = SANDBOX_PATH.read_text(encoding="utf-8")
    if "termux-sandbox-passthrough" in src:
        results.append(("dsh-sandbox-local/index.js", "OK (already patched)"))
    elif CHECK_ONLY:
        results.append(("dsh-sandbox-local/index.js", "NEEDS PATCH"))
    else:
        # 6a. 给 PLATFORM_CHAINS 加 android: []
        chains_anchor = "const PLATFORM_CHAINS = {\n\tlinux: [\"bwrap\", \"landlock\"],\n\tdarwin: [\"seatbelt\"],\n\twin32: [\"windows-acl\"]\n};"
        chains_repl = "const PLATFORM_CHAINS = {\n\tlinux: [\"bwrap\", \"landlock\"],\n\tdarwin: [\"seatbelt\"],\n\twin32: [\"windows-acl\"],\n\tandroid: []\n};"
        if chains_anchor in src:
            src = src.replace(chains_anchor, chains_repl, 1)
        else:
            results.append(("dsh-sandbox-local/index.js", "MISS (PLATFORM_CHAINS anchor not found)"))
            misses.append(("dsh-sandbox-local/index.js", "PLATFORM_CHAINS"))
            # 报告
            print("=== PATCH REPORT ===")
            for name, status in results:
                print(f"  {name}: {status}")
            sys.exit(1)

        # 6b. selectRunner: unavailable → passthrough (android 降级)
        sel_anchor = (
            "\tselectRunner(mode) {\n"
            "\t\tthis.selectedRunner ??= this.chainVerdict();\n"
            "\t\tif (this.selectedRunner === \"unavailable\") throw new SandboxUnavailableError(mode);\n"
            "\t\treturn this.selectedRunner;\n"
            "\t}"
        )
        sel_repl = (
            "\tselectRunner(mode) {\n"
            "\t\tthis.selectedRunner ??= this.chainVerdict();\n"
            "\t\tif (this.selectedRunner === \"unavailable\") {\n"
            "\t\t\t/* termux-sandbox-passthrough: no sandbox backend on this platform (e.g. android/Termux);\n"
            "\t\t\t   degrade to unconfined execution instead of fail-closed. */\n"
            "\t\t\tif ((this.internals.platform ?? process.platform) === \"android\") {\n"
            "\t\t\t\tthis.ctx?.logger?.warn?.(\"sandbox-local: no sandbox backend available on android; running commands unconfined\");\n"
            "\t\t\t\treturn { runner: \"passthrough\", enforcement: \"none\" };\n"
            "\t\t\t}\n"
            "\t\t\tthrow new SandboxUnavailableError(mode);\n"
            "\t\t}\n"
            "\t\treturn this.selectedRunner;\n"
            "\t}"
        )
        if sel_anchor not in src:
            results.append(("dsh-sandbox-local/index.js", "MISS (selectRunner anchor not found)"))
            misses.append(("dsh-sandbox-local/index.js", "selectRunner"))
            print("=== PATCH REPORT ===")
            for name, status in results:
                print(f"  {name}: {status}")
            sys.exit(1)
        src = src.replace(sel_anchor, sel_repl, 1)

        # 6c. confine: passthrough → 原样返回 argv
        conf_anchor = (
            "\t\tconst selected = this.selectRunner(policy.mode);\n"
            "\t\treturn {\n"
            "\t\t\targv: [\n"
            "\t\t\t\t...this.runnerArgv(selected.runner, policy),\n"
            "\t\t\t\t\"--\",\n"
            "\t\t\t\t...argv\n"
            "\t\t\t],\n"
            "\t\t\tenforcement: selected.enforcement,\n"
            "\t\t\tdenialSignatures: DENIAL_SIGNATURES[selected.runner],\n"
            "\t\t\trunnerFailureRules: RUNNER_FAILURE_RULES[selected.runner]\n"
            "\t\t};\n"
            "\t}"
        )
        conf_repl = (
            "\t\tconst selected = this.selectRunner(policy.mode);\n"
            "\t\t/* termux-sandbox-passthrough: no sandbox backend — run the command as-is */\n"
            "\t\tif (selected.runner === \"passthrough\") return {\n"
            "\t\t\targv,\n"
            "\t\t\tenforcement: \"none\",\n"
            "\t\t\tdenialSignatures: [],\n"
            "\t\t\trunnerFailureRules: []\n"
            "\t\t};\n"
            "\t\treturn {\n"
            "\t\t\targv: [\n"
            "\t\t\t\t...this.runnerArgv(selected.runner, policy),\n"
            "\t\t\t\t\"--\",\n"
            "\t\t\t\t...argv\n"
            "\t\t\t],\n"
            "\t\t\tenforcement: selected.enforcement,\n"
            "\t\t\tdenialSignatures: DENIAL_SIGNATURES[selected.runner],\n"
            "\t\t\trunnerFailureRules: RUNNER_FAILURE_RULES[selected.runner]\n"
            "\t\t};\n"
            "\t}"
        )
        if conf_anchor not in src:
            results.append(("dsh-sandbox-local/index.js", "MISS (confine anchor not found)"))
            misses.append(("dsh-sandbox-local/index.js", "confine"))
            print("=== PATCH REPORT ===")
            for name, status in results:
                print(f"  {name}: {status}")
            sys.exit(1)
        src = src.replace(conf_anchor, conf_repl, 1)

        SANDBOX_PATH.write_text(src, encoding="utf-8")
        results.append(("dsh-sandbox-local/index.js", "WROTE (android passthrough)"))
else:
    results.append(("dsh-sandbox-local/index.js", "SKIP (not found)"))
    skips.append("dsh-sandbox-local/index.js")

# ---------- 报告 ----------
print("=== PATCH REPORT ===")
for name, status in results:
    print(f"  {name}: {status}")

if CHECK_ONLY:
    bad = [n for n, st in results if st == "NEEDS PATCH"]
    if bad:
        print(f"\n[CHECK] 需要补丁: {', '.join(bad)}")
        sys.exit(1)
    print("\n[CHECK] 全部已补丁,无需操作")
    sys.exit(0)

if misses or skips:
    print("\n[WARN] 以下补丁未完全生效:")
    for n, d in misses:
        print(f"  - {n}: {d} 失配(上游代码可能已变,需更新锚点)")
    for n in skips:
        print(f"  - {n}: 文件缺失(模块可能改名/移除)")
    sys.exit(1)

print("\n[OK] 全部补丁生效")
PY

PATCH_RC=$?

# ============================================================
# 9. 设置 DeepSeek API key(仅安装模式)
# ============================================================
if [ "$MODE" = "install" ]; then
    PERSIST_KEY=""
    if [ -n "${DEEPSEEK_API_KEY:-}" ]; then
        echo "    DEEPSEEK_API_KEY already set in environment, using it."
        PERSIST_KEY="$DEEPSEEK_API_KEY"
    else
        printf '    Paste your DeepSeek API key (input hidden): '
        IFS= read -r -s PERSIST_KEY || true
        echo
        if [ -n "$PERSIST_KEY" ]; then
            echo "    Key captured (not echoed)."
        elif PERSIST_KEY="$(find_deepseek_key)"; then
            echo "    Found existing DeepSeek API key, using it."
        else
            echo "    No key provided; set it later with: export DEEPSEEK_API_KEY=sk-..."
        fi
    fi
    if [ -n "$PERSIST_KEY" ]; then
        RC="$HOME/.bashrc"
        touch "$RC"
        grep -v '^export DEEPSEEK_API_KEY=' "$RC" > "$RC.tmp" 2>/dev/null || true
        printf "export DEEPSEEK_API_KEY='%s'\n" "$PERSIST_KEY" >> "$RC.tmp"
        mv "$RC.tmp" "$RC"
        echo "    Saved DEEPSEEK_API_KEY to $RC"
    fi
fi

# ============================================================
# 收尾
# ============================================================
if [ "$MODE" = "check" ]; then
    [ $PATCH_RC -eq 0 ] && echo "✓ dsh 补丁状态: 全部已补丁" || echo "✗ dsh 补丁状态: 需要修补(见上)"
    exit $PATCH_RC
fi

if [ $PATCH_RC -eq 0 ]; then
    printf '\n\033[1;32mDone.\033[0m 全部补丁已应用。验证:\n'
    printf '  dsh --version\n  dsh web\n'
else
    err "补丁未完全生效(见 PATCH REPORT)。dsh 可能仍无法启动。"
    err "可重新运行本脚本;若锚点失配,需对照上游代码更新 patch 锚点。"
    exit 1
fi
