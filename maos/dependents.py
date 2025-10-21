import os
import shutil
import subprocess
import sys
import argparse
from unittest.signals import registerResult


def is_system_library(path):
    if not path:
        return True
    abs_path = os.path.realpath(path)
    system_prefixes = (
        "/usr/lib/",
        "/System",
    )
    return any(abs_path.startswith(prefix) for prefix in system_prefixes)


def is_link(path):
    return os.path.islink(path)


def run_cmd(args):
    try:
        result = subprocess.run(
            args,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{exc.stderr}")


def parse_dependencies(file_path):
    out = run_cmd(["otool", "-L", file_path])
    lines = out.splitlines()
    deps = []
    for line in lines[1:]:
        line = line.strip()
        if not line:
            continue
        # /path/to/lib.dylib (compatibility version X, current version Y)
        # @rpath/libxyz.dylib (compatibility ...)
        if " (" in line:
            dep = line.split(" (", 1)[0].strip()
        else:
            dep = line
        if dep:
            deps.append(dep)
    return deps


def get_rpaths(file_path):
    out = run_cmd(["otool", "-l", file_path])
    lines = out.splitlines()
    rpaths = []
    in_rpath_cmd = False
    for line in lines:
        s = line.strip()
        if s.startswith("cmd "):
            in_rpath_cmd = s == "cmd LC_RPATH"
            continue
        if in_rpath_cmd and s.startswith("path "):
            # 形如：path /usr/local/lib (offset 12)
            path_part = s[5:]  # 去掉前缀 "path "
            if " (" in path_part:
                path_part = path_part.split(" (", 1)[0].strip()
            if path_part:
                rpaths.append(path_part)
    return rpaths


def expand_special_path(raw_path, loader_dir, exec_path, rpaths):

    def expand_anchor(p):
        if p.startswith("@loader_path/"):
            return os.path.normpath(os.path.join(loader_dir, p[len("@loader_path/"):]))
        if p.startswith("@executable_path/"):
            return os.path.normpath(os.path.join(exec_path, p[len("@executable_path/"):]))
        return p

    if raw_path.startswith("/"):
        return raw_path

    if raw_path.startswith("@loader_path/") or raw_path.startswith("@executable_path/"):
        return expand_anchor(raw_path)

    # 依赖项为 @rpath 开头，逐个 RPATH 尝试解析
    if raw_path.startswith("@rpath/"):
        tail = raw_path[len("@rpath/"):]
        for rp in rpaths:
            base = expand_anchor(rp)
            if not base:
                continue
            candidate = os.path.normpath(os.path.join(base, tail))
            if os.path.exists(candidate):
                return candidate

    return None


def ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def install_name_change(file_path, old_full_path, new_full_path):
    if old_full_path == new_full_path:
        return
    run_cmd(["install_name_tool", "-change", old_full_path, new_full_path, file_path])


def install_name_id(file_path, id):
    run_cmd(["install_name_tool", "-id", id, file_path])


def add_rpath(file_path, rpath):
    run_cmd(["install_name_tool", "-add_rpath", rpath, file_path])



def relative_path(dir_path, a):
    return os.path.relpath(dir_path, a)


def copy_link_and_file(src_path, dst_path):
    shutil.copy2(src_path, dst_path, follow_symlinks=False)
    if is_link(src_path):
        real_src_path = os.path.realpath(src_path)
        real_dst_path = os.path.join(os.path.dirname(dst_path), os.path.basename(real_src_path))
        copy_link_and_file(real_src_path, real_dst_path)
        # 确保指定的是新的文件
        if os.path.realpath(dst_path) != os.path.realpath(real_dst_path):
            os.remove(dst_path)
            os.symlink(real_dst_path, dst_path)
        

def copy_dependents(src_path, output_dir):
    visited = set()
    src_is_dylib = src_path.endswith(".dylib")
    copied_files = set()
    unsupport_files = set()
    src_rpaths = []
    exec_path = os.path.dirname(src_path)
    if not src_is_dylib:
        src_rpaths = get_rpaths(src_path)
    ensure_dir(output_dir)

    def process_one(file_path):
        abs_file = os.path.realpath(file_path)
        if abs_file in visited:
            return
        visited.add(abs_file)

        loader_dir = os.path.dirname(abs_file)
        rpaths = src_rpaths + get_rpaths(abs_file)
        deps = parse_dependencies(abs_file)

        for dep in deps:
            if src_is_dylib and dep.startswith("@"):
                unsupport_files.add(dep)
                continue
            resolved = expand_special_path(dep, loader_dir, exec_path, rpaths)
            if not resolved:
                unsupport_files.add(dep)
                continue

            if is_system_library(resolved):
                continue

            basename = os.path.basename(resolved)
            dst_path = os.path.join(output_dir, basename)
 
            if not os.path.exists(dst_path):
                copy_link_and_file(resolved, dst_path)
                copied_files.add(resolved)

            # 递归处理该依赖
            process_one(resolved)

    process_one(os.path.abspath(src_path))

    return { 
        "copied_files": list(copied_files),
        "unsupport_files": list(unsupport_files),
    }


def set_file_rpath_depentents(path, depent_dir):
    unsupport_files = set()
    deps = parse_dependencies(path)
    for dep in deps:
        if is_system_library(dep):
            continue
        if dep.startswith("@"):
            continue
        name = os.path.basename(dep)

        if os.path.exists(os.path.join(depent_dir, name)):
            if os.path.basename(os.path.realpath(dep)) == os.path.basename(os.path.realpath(path)):
                install_name_id(path, "@rpath/" + os.path.basename(dep))
            else:
                install_name_change(path, dep, f"@rpath/{name}")
        else:
            unsupport_files.add(dep)

    new_deps = parse_dependencies(path)
    for dep in new_deps:
        if is_system_library(dep):
            continue

        if dep.startswith("@"):
            continue

        unsupport_files.add(dep)
    
    if not path.endswith(".dylib"):
        add_rpath(path, "@executable_path")
        if depent_dir != os.path.dirname(path):
            add_rpath(path, relative_path(depent_dir, os.path.dirname(path)))

    return {
        "unsupport_files": list(unsupport_files),
    }


def set_dir_rpath_depentents(dir, depent_dir):
    unsupport_files = set()
    for file in os.listdir(dir):
        path = os.path.join(dir, file)
        if is_link(path) or os.path.isdir(path):
            continue

        result = set_file_rpath_depentents(path, depent_dir)
        unsupport_files.update(result["unsupport_files"])
    return {
        "unsupport_files": list(unsupport_files),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command")
    subparsers.required = True

    dependents_parser = subparsers.add_parser("copy-dependents")
    dependents_parser.add_argument("-t", "--target", type=str, required=True, help="target file")
    dependents_parser.add_argument("-o", "--output", type=str, required=True, help="output directory")

    rpath_parser = subparsers.add_parser("set-rpath")
    rpath_parser.add_argument("-t", "--target", type=str, required=True, help="target file or directory")
    rpath_parser.add_argument("-d", "--dir", type=str, required=True, help="dependent directory")

    print_parser = subparsers.add_parser("print")
    print_parser.add_argument("-t", "--target", type=str, required=True, help="target file")

    args = parser.parse_args()

    if args.command == "copy-dependents":
        result = copy_dependents(args.target, args.output)["unsupport_files"]
        if len(result) > 0:
            print(f"copy_dependents unsupport files: {result}")
            exit(1)
        
        result = set_dir_rpath_depentents(args.output, args.output)["unsupport_files"]
        if len(result) > 0:
            print(f"set_dir_rpath_depentents unsupport files: {registerResult}")
            exit(1)

        result = set_file_rpath_depentents(args.target, args.output)["unsupport_files"]
        if len(result) > 0:
            print(f"set_file_rpath_depentents unsupport files: {result}")
            exit(1)
    elif args.command == "set-rpath":
        if os.path.isdir(args.target):
            result = set_dir_rpath_depentents(args.target, args.dir)["unsupport_files"]
            if len(result) > 0:
                print(f"set_dir_rpath_depentents unsupport files: {result}")
                exit(1)
        else:
            result = set_file_rpath_depentents(args.target, args.dir)["unsupport_files"]
            if len(result) > 0:
                print(f"set_file_rpath_depentents unsupport files: {result}")
    elif args.command == "print":
        deps = []
        rpaths = []
        if not os.path.isdir(args.target):
            deps = parse_dependencies(args.target)
            rpaths = get_rpaths(args.target)
        else:
            for file in os.listdir(args.target):
                path = os.path.join(args.target, file)
                if is_link(path) or os.path.isdir(path):
                    continue
                deps.extend(parse_dependencies(path))
                rpaths.extend(get_rpaths(path))

        print(f"**{args.target}**")
        print(f"dependencies:")
        for dep in deps:
            print(f"==> {dep}{' (system)' if is_system_library(dep) else ''}")
        print("\n===========================================\n")
        print(f"rpaths:")
        for rpath in rpaths:
            print(f"==> {rpath}")

    print("done!")