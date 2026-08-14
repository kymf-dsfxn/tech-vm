# Shells out to `ipconfig` and string-matches the English adapter/IPv4 labels,
# so this is Windows-only and locale-dependent.
import re
import subprocess

output = subprocess.check_output("ipconfig", text=True)
adapter = ""
for line in output.splitlines():
    if m := re.match(r"(.+adapter .+):", line):
        adapter = m.group(1)
    elif "IPv4 Address" in line and "127.0" not in line:
        ip = line.split(":")[-1].strip()
        print(f"{adapter}: {ip}")