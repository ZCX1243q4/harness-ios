import io, os, re, sys

ROOT = r"D:\1\harness-ios\Sources"
SHARED = r"D:\1\harness-ios\Shared"
WIDGET = r"D:\1\harness-ios\Widget"

errors = []
warnings = []

def read(p):
    return io.open(p, encoding="utf-8").read()

def strip_noise(src):
    out = []
    i = 0
    n = len(src)
    in_str = False
    in_multi = False
    in_line = False
    in_block = False
    while i < n:
        if in_multi:
            if src.startswith(chr(34)*3, i):
                in_multi = False
                i += 3
            else:
                i += 1
            continue
        if in_block:
            if src.startswith("*/", i):
                in_block = False
                i += 2
            else:
                i += 1
            continue
        if in_line:
            if src[i] == chr(10):
                in_line = False
                out.append(chr(10))
            i += 1
            continue
        if in_str:
            if src[i] == chr(92):
                i += 2
                continue
            if src[i] == chr(34):
                in_str = False
            i += 1
            continue
        if src.startswith(chr(34)*3, i):
            in_multi = True
            i += 3
            continue
        if src.startswith("//", i):
            in_line = True
            i += 2
            continue
        if src.startswith("/*", i):
            in_block = True
            i += 2
            continue
        if src[i] == chr(34):
            in_str = True
            i += 1
            continue
        out.append(src[i])
        i += 1
    return "".join(out)

def check_balance(path, src):
    clean = strip_noise(src)
    stack = []
    pairs = {"}": "{", ")": "(", "]": "["}
    line = 1
    for ch in clean:
        if ch == chr(10):
            line += 1
        elif ch in "{( [".replace(" ", ""):
            stack.append((ch, line))
        elif ch in "})]":
            if not stack:
                errors.append("%s:%d: 多余的 %s" % (os.path.basename(path), line, ch))
                return
            op, ol = stack.pop()
            if op != pairs[ch]:
                errors.append("%s:%d: %s 与第 %d 行的 %s 不匹配" % (os.path.basename(path), line, ch, ol, op))
                return
    for op, ol in stack:
        errors.append("%s:%d: %s 未闭合" % (os.path.basename(path), ol, op))

def check_switch(path, src, cases):
    clean = strip_noise(src)
    lines = clean.split(chr(10))
    for i, l in enumerate(lines):
        st = l.strip()
        if not (st.startswith("switch ") and st.endswith("{")):
            continue
        indent = len(l) - len(l.lstrip())
        end = -1
        for j in range(i+1, len(lines)):
            s = lines[j]
            if s.strip() == "}" and (len(s) - len(s.lstrip())) == indent:
                end = j
                break
        if end < 0:
            continue
        block = chr(10).join(lines[i:end])
        used = []
        for c in cases:
            if re.search(r"[.]" + c + r"", block):
                used.append(c)
        if len(used) >= 2 and len(used) < len(cases):
            missing = [c for c in cases if c not in used]
            errors.append("%s:%d: switch 缺少 %s" % (os.path.basename(path), i+1, missing))

def check_tuple(path, src):
    clean = strip_noise(src)
    for m in re.finditer(r"->s*(s*(w+)s*:s*[w[]<>.]+s*)", clean):
        errors.append("%s: 单元素带标签元组 -> (%s: ...)" % (os.path.basename(path), m.group(1)))

def check_focus(path, src):
    clean = strip_noise(src)
    for m in re.finditer(r"[.]focused($(w+))", clean):
        var = m.group(1)
        if "@FocusState" not in clean:
            errors.append("%s: .focused($%s) 但无 @FocusState" % (os.path.basename(path), var))
        else:
            if not re.search(r"@FocusState[^" + chr(10) + r"]*" + var, clean):
                errors.append("%s: .focused($%s) 但 %s 不是 @FocusState" % (os.path.basename(path), var, var))

def check_color(path, src):
    clean = strip_noise(src)
    for m in re.finditer(r"foregroundStyle(s*w+s*?s*([^:]+?)s*:s*(.[A-Za-z.]+)s*)", clean):
        errors.append("%s: foregroundStyle 三目混类型" % os.path.basename(path))

def check_result(path, src):
    clean = strip_noise(src)
    if re.search(r"Result<[^>]+,s*Strings*>", clean):
        errors.append("%s: Result<_, String> 非法" % os.path.basename(path))

def check_escape(path, src):
    for m in re.finditer(r"\\\\[(]", src):
        warnings.append("%s: 双反斜杠插值" % os.path.basename(path))

files = []
for d in (ROOT, SHARED, WIDGET):
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith(".swift"):
                files.append(os.path.join(d, f))

print("检查 %d 个 Swift 文件" % len(files))
CASES = ["openAI", "anthropic", "gemini", "onDevice", "localGGUF"]

for p in sorted(files):
    try:
        src = read(p)
    except Exception as e:
        errors.append("%s: 读取失败" % p)
        continue
    check_balance(p, src)
    check_switch(p, src, CASES)
    check_tuple(p, src)
    check_focus(p, src)
    check_color(p, src)
    check_result(p, src)
    check_escape(p, src)

print("=" * 60)
if errors:
    print("发现 %d 个错误：" % len(errors))
    for e in errors:
        print("  [ERROR] " + e)
else:
    print("没有结构性错误")
if warnings:
    print("")
    print("%d 个警告：" % len(warnings))
    for w in warnings:
        print("  [WARN] " + w)
sys.exit(1 if errors else 0)