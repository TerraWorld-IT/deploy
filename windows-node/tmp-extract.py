import tarfile, shutil, os, posixpath, sys, _winapi
tar, dest, prefix = sys.argv[1], sys.argv[2], "app/"
with tarfile.open(tar) as t:
    members = [m for m in t.getmembers() if m.name.startswith(prefix)]
    links = []
    for m in members:
        m.name = m.name[len(prefix):]
        if not m.name: continue
        if m.issym() or m.islnk(): links.append(m); continue
        t.extract(m, dest, filter="fully_trusted" if hasattr(tarfile, "data_filter") else None)
    # 링크: 타깃이 링크일 수도 있으니 해결될 때까지 반복
    pending = links
    for _ in range(10):
        nxt = []
        for m in pending:
            p = os.path.join(dest, m.name)
            tgt = m.linkname if m.islnk() else posixpath.normpath(posixpath.join(posixpath.dirname(m.name), m.linkname))
            if m.islnk(): tgt = tgt[len(prefix):] if tgt.startswith(prefix) else tgt
            src = os.path.join(dest, tgt)
            if not os.path.exists(src): nxt.append(m); continue
            if os.path.lexists(p):
                shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            _winapi.CreateJunction(os.path.abspath(src), os.path.abspath(p)) if os.path.isdir(src) else shutil.copy2(src, p)
        if not nxt: break
        pending = nxt
    print("links", len(links), "unresolved", len(pending if nxt else []), [m.name for m in (nxt or [])][:5])
