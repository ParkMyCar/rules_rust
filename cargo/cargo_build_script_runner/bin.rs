// Copyright 2018 The Bazel Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// A simple wrapper around a build_script execution to generate file to reuse
// by rust_library/rust_binary.
extern crate cargo_build_script_output_parser;

use cargo_build_script_output_parser::{BuildScriptOutput, CompileAndLinkFlags};
use std::collections::BTreeMap;
use std::env;
use std::fs::{create_dir_all, read_to_string, write};
use std::path::{Path, PathBuf};
use std::process::Command;

fn run_buildrs() -> Result<(), String> {
    // We use exec_root.join rather than std::fs::canonicalize, to avoid resolving symlinks, as
    // some execution strategies and remote execution environments may use symlinks in ways which
    // canonicalizing them may break them, e.g. by having input files be symlinks into a /cas
    // directory - resolving these may cause tools which inspect $0, or try to resolve files
    // relative to themselves, to fail.
    let exec_root = env::current_dir().expect("Failed to get current directory");
    let manifest_dir_env = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR was not set");
    let rustc_env = env::var("RUSTC").expect("RUSTC was not set");
    let manifest_dir = exec_root.join(manifest_dir_env);
    let rustc = exec_root.join(&rustc_env);
    let Options {
        progname,
        crate_links,
        out_dir,
        env_file,
        compile_flags_file,
        link_flags_file,
        link_search_paths_file,
        data_files,
        output_dep_env_path,
        stdout_path,
        stderr_path,
        rundir,
        input_dep_env_paths,
    } = parse_args()?;

    let out_dir_abs = exec_root.join(out_dir);
    // For some reason Google's RBE does not create the output directory, force create it.
    create_dir_all(&out_dir_abs)
        .unwrap_or_else(|_| panic!("Failed to make output directory: {:?}", out_dir_abs));

    if should_symlink_exec_root() {
        // Symlink the execroot to the manifest_dir so that we can use relative paths in the arguments.
        let exec_root_paths = std::fs::read_dir(&exec_root)
            .map_err(|err| format!("Failed while listing exec root: {err:?}"))?;
        for path in exec_root_paths {
            let path = path
                .map_err(|err| {
                    format!("Failed while getting path from exec root listing: {err:?}")
                })?
                .path();

            let file_name = path
                .file_name()
                .ok_or_else(|| "Failed while getting file name".to_string())?;
            let link = manifest_dir.join(file_name);

            symlink_if_not_exists(&path, &link)
                .map_err(|err| format!("Failed to symlink {path:?} to {link:?}: {err}"))?;
        }
    }

    let target_env_vars =
        get_target_env_vars(&rustc_env).expect("Error getting target env vars from rustc");

    let working_directory = resolve_rundir(&rundir, &exec_root, &manifest_dir)?;

    // Symlink all of the data files into the working directory so the executable can access them.
    symlink_data_files(&exec_root, &working_directory, &data_files)?;

    let mut command = Command::new(exec_root.join(progname));
    command
        .current_dir(&working_directory)
        .envs(target_env_vars)
        .env("OUT_DIR", out_dir_abs)
        .env("CARGO_MANIFEST_DIR", manifest_dir)
        .env("RUSTC", rustc)
        .env("RUST_BACKTRACE", "full");

    for dep_env_path in input_dep_env_paths.iter() {
        if let Ok(contents) = read_to_string(dep_env_path) {
            for line in contents.split('\n') {
                // split on empty contents will still produce a single empty string in iterable.
                if line.is_empty() {
                    continue;
                }
                match line.split_once('=') {
                    Some((key, value)) => {
                        command.env(key, value.replace("${pwd}", &exec_root.to_string_lossy()));
                    }
                    _ => {
                        return Err(
                            "error: Wrong environment file format, should not happen".to_owned()
                        )
                    }
                }
            }
        } else {
            return Err("error: Dependency environment file unreadable".to_owned());
        }
    }

    for tool_env_var in &["CC", "CXX", "LD"] {
        if let Some(tool_path) = env::var_os(tool_env_var) {
            command.env(tool_env_var, exec_root.join(tool_path));
        }
    }

    if let Some(ar_path) = env::var_os("AR") {
        // The default OSX toolchain uses libtool as ar_executable not ar.
        // This doesn't work when used as $AR, so simply don't set it - tools will probably fall back to
        // /usr/bin/ar which is probably good enough.
        if Path::new(&ar_path).file_name() == Some("libtool".as_ref()) {
            command.env_remove("AR");
        } else {
            command.env("AR", exec_root.join(ar_path));
        }
    }

    // replace env vars with a ${pwd} prefix with the exec_root
    for (key, value) in env::vars() {
        let exec_root_str = exec_root.to_str().expect("exec_root not in utf8");
        if value.contains("${pwd}") {
            env::set_var(key, value.replace("${pwd}", exec_root_str));
        }
    }

    // Bazel does not support byte strings so in order to correctly represent `CARGO_ENCODED_RUSTFLAGS`
    // the escaped `\x1f` sequences need to be unescaped
    if let Ok(encoded_rustflags) = env::var("CARGO_ENCODED_RUSTFLAGS") {
        command.env(
            "CARGO_ENCODED_RUSTFLAGS",
            encoded_rustflags.replace("\\x1f", "\x1f"),
        );
    }

    let (buildrs_outputs, process_output) = BuildScriptOutput::outputs_from_command(&mut command)
        .map_err(|process_output| {
        format!(
            "Build script process failed{}\n--stdout:\n{}\n--stderr:\n{}",
            if let Some(exit_code) = process_output.status.code() {
                format!(" with exit code {exit_code}")
            } else {
                String::new()
            },
            String::from_utf8(process_output.stdout)
                .expect("Failed to parse stdout of child process"),
            String::from_utf8(process_output.stderr)
                .expect("Failed to parse stdout of child process"),
        )
    })?;

    write(
        &env_file,
        BuildScriptOutput::outputs_to_env(&buildrs_outputs, &exec_root.to_string_lossy())
            .as_bytes(),
    )
    .unwrap_or_else(|_| panic!("Unable to write file {:?}", env_file));
    write(
        &output_dep_env_path,
        BuildScriptOutput::outputs_to_dep_env(
            &buildrs_outputs,
            &crate_links,
            &exec_root.to_string_lossy(),
        )
        .as_bytes(),
    )
    .unwrap_or_else(|_| panic!("Unable to write file {:?}", output_dep_env_path));
    write(&stdout_path, process_output.stdout)
        .unwrap_or_else(|_| panic!("Unable to write file {:?}", stdout_path));
    write(&stderr_path, process_output.stderr)
        .unwrap_or_else(|_| panic!("Unable to write file {:?}", stderr_path));

    let CompileAndLinkFlags {
        compile_flags,
        link_flags,
        link_search_paths,
    } = BuildScriptOutput::outputs_to_flags(&buildrs_outputs, &exec_root.to_string_lossy());

    write(&compile_flags_file, compile_flags.as_bytes())
        .unwrap_or_else(|_| panic!("Unable to write file {:?}", compile_flags_file));
    write(&link_flags_file, link_flags.as_bytes())
        .unwrap_or_else(|_| panic!("Unable to write file {:?}", link_flags_file));
    write(&link_search_paths_file, link_search_paths.as_bytes())
        .unwrap_or_else(|_| panic!("Unable to write file {:?}", link_search_paths_file));
    Ok(())
}

fn should_symlink_exec_root() -> bool {
    env::var("RULES_RUST_SYMLINK_EXEC_ROOT")
        .map(|s| s == "1")
        .unwrap_or(false)
}

/// Create a symlink from `link` to `original` if `link` doesn't already exist.
#[cfg(windows)]
fn symlink_if_not_exists(original: &Path, link: &Path) -> Result<(), String> {
    if original.is_dir() {
        std::os::windows::fs::symlink_dir(original, link)
            .or_else(swallow_already_exists)
            .map_err(|err| format!("Failed to create directory symlink: {err}"))
    } else {
        std::os::windows::fs::symlink_file(original, link)
            .or_else(swallow_already_exists)
            .map_err(|err| format!("Failed to create file symlink: {err}"))
    }
}

/// Create a symlink from `link` to `original` if `link` doesn't already exist.
#[cfg(not(windows))]
fn symlink_if_not_exists(original: &Path, link: &Path) -> Result<(), String> {
    std::os::unix::fs::symlink(original, link)
        .or_else(swallow_already_exists)
        .map_err(|err| format!("Failed to create symlink: {err}"))
}

fn resolve_rundir(rundir: &str, exec_root: &Path, manifest_dir: &Path) -> Result<PathBuf, String> {
    if rundir.is_empty() {
        return Ok(manifest_dir.to_owned());
    }
    let rundir_path = Path::new(rundir);
    if rundir_path.is_absolute() {
        return Err(format!("rundir must be empty (to run in manifest path) or relative path (relative to exec root), but was {:?}", rundir));
    }
    if rundir_path
        .components()
        .any(|c| c == std::path::Component::ParentDir)
    {
        return Err(format!("rundir must not contain .. but was {:?}", rundir));
    }
    Ok(exec_root.join(rundir_path))
}

fn symlink_data_files(exec_root: &Path, working_directory: &PathBuf, data_files_manifest: &String) -> Result<(), String> {
    let paths = read_to_string(data_files_manifest).map_err(|e| e.to_string())?;

    println!("DEBUG {data_files_manifest:?}");

    // `data_files_manifest` contains a new line for each directory whose contents we need to
    // symlink into the `working_directory`.
    for path in paths.lines() {
        let full_path = exec_root.join(path);
        if !full_path.exists() {
            continue;
        }

        let dir_entries = std::fs::read_dir(&full_path)
            .map_err(|err| format!("Failed while listing exec root: {err:?}"))?;
        
        for entry in dir_entries {
            let data_path = entry
                .map_err(|err| format!("Failed to list entry from {path} listing: {err:?}"))?
                .path();
            let filename = data_path.file_name().ok_or_else(|| "symlinking filesystem root?")?;
            let dest_path = working_directory.join(filename);

            symlink_if_not_exists(&data_path, &dest_path)?;
        }
    }

    Ok(())
}

fn swallow_already_exists(err: std::io::Error) -> std::io::Result<()> {
    if err.kind() == std::io::ErrorKind::AlreadyExists {
        Ok(())
    } else {
        Err(err)
    }
}

/// A representation of expected command line arguments.
struct Options {
    progname: String,
    crate_links: String,
    out_dir: String,
    env_file: String,
    compile_flags_file: String,
    link_flags_file: String,
    link_search_paths_file: String,
    data_files: String,
    output_dep_env_path: String,
    stdout_path: String,
    stderr_path: String,
    rundir: String,
    input_dep_env_paths: Vec<String>,
}

/// Parses positional comamnd line arguments into a well defined struct
fn parse_args() -> Result<Options, String> {
    let mut args = env::args().skip(1);

    // TODO: we should consider an alternative to positional arguments.
    match (args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next(), args.next()) {
        (
            Some(progname),
            Some(crate_links),
            Some(out_dir),
            Some(env_file),
            Some(compile_flags_file),
            Some(link_flags_file),
            Some(link_search_paths_file),
            Some(data_files),
            Some(output_dep_env_path),
            Some(stdout_path),
            Some(stderr_path),
            Some(rundir),
        ) => {
            Ok(Options{
                progname,
                crate_links,
                out_dir,
                env_file,
                compile_flags_file,
                link_flags_file,
                link_search_paths_file,
                data_files,
                output_dep_env_path,
                stdout_path,
                stderr_path,
                rundir,
                input_dep_env_paths: args.collect(),
            })
        }
        _ => {
            Err(format!("Usage: $0 progname crate_links out_dir env_file compile_flags_file link_flags_file link_search_paths_file output_dep_env_path stdout_path stderr_path input_dep_env_paths[arg1...argn]\nArguments passed: {:?}", args.collect::<Vec<String>>()))
        }
    }
}

fn get_target_env_vars<P: AsRef<Path>>(rustc: &P) -> Result<BTreeMap<String, String>, String> {
    // As done by Cargo when constructing a cargo::core::compiler::build_context::target_info::TargetInfo.
    let output = Command::new(rustc.as_ref())
        .arg("--print=cfg")
        .arg(format!(
            "--target={}",
            env::var("TARGET").expect("missing TARGET")
        ))
        .output()
        .map_err(|err| format!("Error running rustc to get target information: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "Error running rustc to get target information: {output:?}",
        ));
    }
    let stdout = std::str::from_utf8(&output.stdout)
        .map_err(|err| format!("Non-UTF8 stdout from rustc: {err:?}"))?;

    Ok(parse_rustc_cfg_output(stdout))
}

fn parse_rustc_cfg_output(stdout: &str) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();

    for line in stdout.lines() {
        if line.starts_with("target_") && line.contains('=') {
            // UNWRAP: Verified that line contains = and split into exactly 2 parts.
            let (key, value) = line.split_once('=').unwrap();
            if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
                values
                    .entry(key)
                    .or_insert_with(Vec::new)
                    .push(value[1..(value.len() - 1)].to_owned());
            }
        } else if ["windows", "unix"].contains(&line) {
            // the 'windows' or 'unix' line received from rustc will be turned
            // into eg. CARGO_CFG_WINDOWS='' below
            values.insert(line, vec![]);
        }
    }

    values
        .into_iter()
        .map(|(key, value)| (format!("CARGO_CFG_{}", key.to_uppercase()), value.join(",")))
        .collect()
}

fn main() {
    std::process::exit(match run_buildrs() {
        Ok(_) => 0,
        Err(err) => {
            // Neatly print errors
            eprintln!("{err}");
            1
        }
    });
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn rustc_cfg_parsing() {
        let macos_output = r#"\
debug_assertions
target_arch="x86_64"
target_endian="little"
target_env=""
target_family="unix"
target_feature="fxsr"
target_feature="sse"
target_feature="sse2"
target_feature="sse3"
target_feature="ssse3"
target_os="macos"
target_pointer_width="64"
target_vendor="apple"
unix
"#;
        let tree = parse_rustc_cfg_output(macos_output);
        assert_eq!(tree["CARGO_CFG_UNIX"], "");
        assert_eq!(tree["CARGO_CFG_TARGET_FAMILY"], "unix");

        let windows_output = r#"\
debug_assertions
target_arch="x86_64"
target_endian="little"
target_env="msvc"
target_family="windows"
target_feature="fxsr"
target_feature="sse"
target_feature="sse2"
target_os="windows"
target_pointer_width="64"
target_vendor="pc"
windows
"#;
        let tree = parse_rustc_cfg_output(windows_output);
        assert_eq!(tree["CARGO_CFG_WINDOWS"], "");
        assert_eq!(tree["CARGO_CFG_TARGET_FAMILY"], "windows");
    }
}
