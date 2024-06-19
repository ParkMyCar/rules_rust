"""Rules for Cargo build scripts (`build.rs` files)"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("//rust:defs.bzl", "rust_common")
load("//rust:rust_common.bzl", "BuildInfo", "DepInfo")

# buildifier: disable=bzl-visibility
load(
    "//rust/private:rustc.bzl",
    "get_compilation_mode_opts",
    "get_linker_and_args",
)

# buildifier: disable=bzl-visibility
load(
    "//rust/private:utils.bzl",
    "dedent",
    "expand_dict_value_locations",
    "find_cc_toolchain",
    "find_toolchain",
    _name_to_crate_name = "name_to_crate_name",
)

# Reexport for cargo_build_script_wrapper.bzl
name_to_crate_name = _name_to_crate_name

def get_cc_compile_args_and_env(cc_toolchain, feature_configuration):
    """Gather cc environment variables from the given `cc_toolchain`

    Args:
        cc_toolchain (cc_toolchain): The current rule's `cc_toolchain`.
        feature_configuration (FeatureConfiguration): Class used to construct command lines from CROSSTOOL features.

    Returns:
        tuple: A tuple of the following items:
            - (sequence): A flattened C command line flags for given action.
            - (sequence): A flattened CXX command line flags for given action.
            - (dict): C environment variables to be set for given action.
    """
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
    )
    cc_c_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
        variables = compile_variables,
    )
    cc_cxx_args = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.cpp_compile,
        variables = compile_variables,
    )
    cc_env = cc_common.get_environment_variables(
        feature_configuration = feature_configuration,
        action_name = ACTION_NAMES.c_compile,
        variables = compile_variables,
    )
    return cc_c_args, cc_cxx_args, cc_env

def _pwd_flags_sysroot(args):
    """Prefix execroot-relative paths of known arguments with ${pwd}.

    Args:
        args (list): List of tool arguments.

    Returns:
        list: The modified argument list.
    """
    res = []
    for arg in args:
        s, opt, path = arg.partition("--sysroot=")
        if s == "" and not paths.is_absolute(path):
            res.append("{}${{pwd}}/{}".format(opt, path))
        else:
            res.append(arg)
    return res

def _pwd_flags_isystem(args):
    """Prefix execroot-relative paths of known arguments with ${pwd}.

    Args:
        args (list): List of tool arguments.

    Returns:
        list: The modified argument list.
    """
    res = []
    fix_next_arg = False
    for arg in args:
        if fix_next_arg and not paths.is_absolute(arg):
            res.append("${{pwd}}/{}".format(arg))
        else:
            res.append(arg)

        fix_next_arg = arg == "-isystem"

    return res

def _pwd_flags(args):
    return _pwd_flags_isystem(_pwd_flags_sysroot(args))

def _feature_enabled(ctx, feature_name, default = False):
    """Check if a feature is enabled.

    If the feature is explicitly enabled or disabled, return accordingly.

    In the case where the feature is not explicitly enabled or disabled, return the default value.

    Args:
        ctx: The context object.
        feature_name: The name of the feature.
        default: The default value to return if the feature is not explicitly enabled or disabled.

    Returns:
        Boolean defining whether the feature is enabled.
    """
    if feature_name in ctx.disabled_features:
        return False

    if feature_name in ctx.features:
        return True

    return default

def _cargo_build_script_impl(ctx):
    """The implementation for the `cargo_build_script` rule.

    Args:
        ctx (ctx): The rules context object

    Returns:
        list: A list containing a BuildInfo provider
    """
    script = ctx.executable.script
    toolchain = find_toolchain(ctx)
    out_dir = ctx.actions.declare_directory(ctx.label.name + ".out_dir")
    env_out = ctx.actions.declare_file(ctx.label.name + ".env")
    dep_env_out = ctx.actions.declare_file(ctx.label.name + ".depenv")
    flags_out = ctx.actions.declare_file(ctx.label.name + ".flags")
    link_flags = ctx.actions.declare_file(ctx.label.name + ".linkflags")
    link_search_paths = ctx.actions.declare_file(ctx.label.name + ".linksearchpaths")  # rustc-link-search, propagated from transitive dependencies
    data_files = ctx.actions.declare_file(ctx.label.name + ".datafiles")
    manifest_dir = "%s.runfiles/%s/%s" % (script.path, ctx.label.workspace_name or ctx.workspace_name, ctx.label.package)
    compilation_mode_opt_level = get_compilation_mode_opts(ctx, toolchain).opt_level

    streams = struct(
        stdout = ctx.actions.declare_file(ctx.label.name + ".stdout.log"),
        stderr = ctx.actions.declare_file(ctx.label.name + ".stderr.log"),
    )

    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = name_to_pkg_name(ctx.label.name)

    toolchain_tools = [toolchain.all_files]

    cc_toolchain = find_cpp_toolchain(ctx)

    # Start with the default shell env, which contains any --action_env
    # settings passed in on the command line.
    env = dict(ctx.configuration.default_shell_env)

    env.update({
        "CARGO_CRATE_NAME": name_to_crate_name(pkg_name),
        "CARGO_MANIFEST_DIR": manifest_dir,
        "CARGO_PKG_NAME": pkg_name,
        "HOST": toolchain.exec_triple.str,
        "NUM_JOBS": "1",
        "OPT_LEVEL": compilation_mode_opt_level,
        "RUSTC": toolchain.rustc.path,
        "TARGET": toolchain.target_flag_value,
        # OUT_DIR is set by the runner itself, rather than on the action.
    })

    # This isn't exactly right, but Bazel doesn't have exact views of "debug" and "release", so...
    env.update({
        "DEBUG": {"dbg": "true", "fastbuild": "true", "opt": "false"}.get(ctx.var["COMPILATION_MODE"], "true"),
        "PROFILE": {"dbg": "debug", "fastbuild": "debug", "opt": "release"}.get(ctx.var["COMPILATION_MODE"], "unknown"),
    })

    if ctx.attr.version:
        version = ctx.attr.version.split("+")[0].split(".")
        patch = version[2].split("-") if len(version) > 2 else [""]
        env["CARGO_PKG_VERSION_MAJOR"] = version[0]
        env["CARGO_PKG_VERSION_MINOR"] = version[1] if len(version) > 1 else ""
        env["CARGO_PKG_VERSION_PATCH"] = patch[0]
        env["CARGO_PKG_VERSION_PRE"] = patch[1] if len(patch) > 1 else ""
        env["CARGO_PKG_VERSION"] = ctx.attr.version

    # Pull in env vars which may be required for the cc_toolchain to work (e.g. on OSX, the SDK version).
    # We hope that the linker env is sufficient for the whole cc_toolchain.
    cc_toolchain, feature_configuration = find_cc_toolchain(ctx)
    linker, link_args, linker_env = get_linker_and_args(ctx, ctx.attr, "bin", cc_toolchain, feature_configuration, None)
    env.update(**linker_env)
    env["LD"] = linker
    env["LDFLAGS"] = " ".join(_pwd_flags(link_args))

    # MSVC requires INCLUDE to be set
    cc_c_args, cc_cxx_args, cc_env = get_cc_compile_args_and_env(cc_toolchain, feature_configuration)
    include = cc_env.get("INCLUDE")
    if include:
        env["INCLUDE"] = include

    if cc_toolchain:
        toolchain_tools.append(cc_toolchain.all_files)

        env["CC"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.c_compile,
        )
        env["CXX"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.cpp_compile,
        )
        env["AR"] = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = ACTION_NAMES.cpp_link_static_library,
        )

        # Populate CFLAGS and CXXFLAGS that cc-rs relies on when building from source, in particular
        # to determine the deployment target when building for apple platforms (`macosx-version-min`
        # for example, itself derived from the `macos_minimum_os` Bazel argument).
        env["CFLAGS"] = " ".join(_pwd_flags(cc_c_args))
        env["CXXFLAGS"] = " ".join(_pwd_flags(cc_cxx_args))

    # Inform build scripts of rustc flags
    # https://github.com/rust-lang/cargo/issues/9600
    env["CARGO_ENCODED_RUSTFLAGS"] = "\\x1f".join([
        # Allow build scripts to locate the generated sysroot
        "--sysroot=${{pwd}}/{}".format(toolchain.sysroot),
    ] + ctx.attr.rustc_flags)

    for f in ctx.attr.crate_features:
        env["CARGO_FEATURE_" + f.upper().replace("-", "_")] = "1"

    links = ctx.attr.links or ""
    if links:
        env["CARGO_MANIFEST_LINKS"] = links

    # Add environment variables from the Rust toolchain.
    env.update(toolchain.env)

    # Gather data from the `toolchains` attribute.
    for target in ctx.attr.toolchains:
        if DefaultInfo in target:
            toolchain_tools.extend([
                target[DefaultInfo].files,
                target[DefaultInfo].default_runfiles.files,
            ])
        if platform_common.ToolchainInfo in target:
            all_files = getattr(target[platform_common.ToolchainInfo], "all_files", depset([]))
            if type(all_files) == "list":
                all_files = depset(all_files)
            toolchain_tools.append(all_files)
        if platform_common.TemplateVariableInfo in target:
            variables = getattr(target[platform_common.TemplateVariableInfo], "variables", depset([]))
            env.update(variables)

    _merge_env_dict(env, expand_dict_value_locations(
        ctx,
        ctx.attr.build_script_env,
        getattr(ctx.attr, "data", []) +
        getattr(ctx.attr, "compile_data", []) +
        getattr(ctx.attr, "tools", []),
    ))

    tools = depset(
        direct = [
            script,
            ctx.executable._cargo_build_script_runner,
        ] + ctx.files.tools + ([toolchain.target_json] if toolchain.target_json else []),
        transitive = toolchain_tools,
    )

    # Generate the set of paths that we need to provide to the build script.
    data_roots = {}
    for entry in ctx.attr.data:
        files = entry[DefaultInfo].files
        for file in files.to_list():
            path = "{0}/{1}".format(file.root.path, entry.label.workspace_root)
            path = path.removeprefix("/")

            # Use a dictionary with all of the same values to emulate a set.
            data_roots[path] = True

    # Always include the manifest dir.
    print(ctx.label.workspace_name)
    print(ctx.workspace_name)
    print(ctx.label.package)
    data_manifest_dir = "{0}/{1}".format(ctx.label.workspace_name or ctx.workspace_name, ctx.label.package)
    data_roots[data_manifest_dir] = True

    print(data_roots)

    ctx.actions.write(
        output = data_files,
        content = "\n".join([path for path in data_roots.keys()]),
    )

    # dep_env_file contains additional environment variables coming from
    # direct dependency sys-crates' build scripts. These need to be made
    # available to the current crate build script.
    # See https://doc.rust-lang.org/cargo/reference/build-scripts.html#-sys-packages
    # for details.
    args = ctx.actions.args()
    args.add(script)
    args.add(links)
    args.add(out_dir.path)
    args.add(env_out)
    args.add(flags_out)
    args.add(link_flags)
    args.add(link_search_paths)
    args.add(data_files)
    args.add(dep_env_out)
    args.add(streams.stdout)
    args.add(streams.stderr)
    args.add(ctx.attr.rundir)

    build_script_inputs = []
    for dep in ctx.attr.link_deps:
        if rust_common.dep_info in dep and dep[rust_common.dep_info].dep_env:
            dep_env_file = dep[rust_common.dep_info].dep_env
            args.add(dep_env_file.path)
            build_script_inputs.append(dep_env_file)
            for dep_build_info in dep[rust_common.dep_info].transitive_build_infos.to_list():
                build_script_inputs.append(dep_build_info.out_dir)

    for dep in ctx.attr.deps:
        for dep_build_info in dep[rust_common.dep_info].transitive_build_infos.to_list():
            build_script_inputs.append(dep_build_info.out_dir)

    inputs = depset([data_files] + ctx.files.data + build_script_inputs)

    experimental_symlink_execroot = ctx.attr._experimental_symlink_execroot[BuildSettingInfo].value or \
                                    _feature_enabled(ctx, "symlink-exec-root")

    if experimental_symlink_execroot:
        env["RULES_RUST_SYMLINK_EXEC_ROOT"] = "1"

    ctx.actions.run(
        executable = ctx.executable._cargo_build_script_runner,
        arguments = [args],
        outputs = [out_dir, env_out, flags_out, link_flags, link_search_paths, dep_env_out, streams.stdout, streams.stderr],
        tools = tools,
        inputs = inputs,
        mnemonic = "CargoBuildScriptRun",
        progress_message = "Running Cargo build script {}".format(pkg_name),
        env = env,
        toolchain = None,
        # Set use_default_shell_env so that $PATH is set, as tools like cmake may want to probe $PATH for helper tools.
        use_default_shell_env = True,
    )

    return [
        # Although this isn't used anywhere, without this, `bazel build`'ing
        # the cargo_build_script label won't actually run the build script
        # since bazel is lazy.
        DefaultInfo(files = depset([out_dir])),
        BuildInfo(
            out_dir = out_dir,
            rustc_env = env_out,
            dep_env = dep_env_out,
            flags = flags_out,
            linker_flags = link_flags,
            link_search_paths = link_search_paths,
            compile_data = depset([]),
        ),
        OutputGroupInfo(
            streams = depset([streams.stdout, streams.stderr]),
            out_dir = depset([out_dir]),
        ),
    ]

cargo_build_script = rule(
    doc = (
        "A rule for running a crate's `build.rs` files to generate build information " +
        "which is then used to determine how to compile said crate."
    ),
    implementation = _cargo_build_script_impl,
    attrs = {
        "build_script_env": attr.string_dict(
            doc = "Environment variables for build scripts.",
        ),
        "crate_features": attr.string_list(
            doc = "The list of rust features that the build script should consider activated.",
        ),
        "data": attr.label_list(
            doc = "Data required by the build script.",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "The Rust build-dependencies of the crate",
            providers = [rust_common.dep_info],
            cfg = "exec",
        ),
        "link_deps": attr.label_list(
            doc = dedent("""\
                The subset of the Rust (normal) dependencies of the crate that
                have the links attribute and therefore provide environment
                variables to this build script.
            """),
            providers = [rust_common.dep_info],
        ),
        "links": attr.string(
            doc = "The name of the native library this crate links against.",
        ),
        "pkg_name": attr.string(
            doc = "The name of package being compiled, if not derived from `name`.",
        ),
        "rundir": attr.string(
            default = "",
            doc = dedent("""\
                A directory to cd to before the cargo_build_script is run. This should be a path relative to the exec root.

                The default behaviour (and the behaviour if rundir is set to the empty string) is to change to the relative path corresponding to the cargo manifest directory, which replicates the normal behaviour of cargo so it is easy to write compatible build scripts.

                If set to `.`, the cargo build script will run in the exec root.
            """),
        ),
        "rustc_flags": attr.string_list(
            doc = dedent("""\
                List of compiler flags passed to `rustc`.

                These strings are subject to Make variable expansion for predefined
                source/output path variables like `$location`, `$execpath`, and
                `$rootpath`. This expansion is useful if you wish to pass a generated
                file of arguments to rustc: `@$(location //package:target)`.
            """),
        ),
        # The source of truth will be the `cargo_build_script` macro until stardoc
        # implements documentation inheritence. See https://github.com/bazelbuild/stardoc/issues/27
        "script": attr.label(
            doc = "The binary script to run, generally a `rust_binary` target.",
            executable = True,
            allow_files = True,
            mandatory = True,
            cfg = "exec",
        ),
        "tools": attr.label_list(
            doc = "Tools required by the build script.",
            allow_files = True,
            cfg = "exec",
        ),
        "version": attr.string(
            doc = "The semantic version (semver) of the crate",
        ),
        "_cargo_build_script_runner": attr.label(
            executable = True,
            allow_files = True,
            default = Label("//cargo/cargo_build_script_runner:cargo_build_script_runner"),
            cfg = "exec",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
        "_experimental_symlink_execroot": attr.label(
            default = Label("//cargo/settings:experimental_symlink_execroot"),
        ),
    },
    fragments = ["cpp"],
    toolchains = [
        str(Label("//rust:toolchain_type")),
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
)

def _merge_env_dict(prefix_dict, suffix_dict):
    """Merges suffix_dict into prefix_dict, appending rather than replacing certain env vars."""
    for key in ["CFLAGS", "CXXFLAGS", "LDFLAGS"]:
        if key in prefix_dict and key in suffix_dict and prefix_dict[key]:
            prefix_dict[key] += " " + suffix_dict.pop(key)
    prefix_dict.update(suffix_dict)

def name_to_pkg_name(name):
    """Sanitize the name of cargo_build_script targets.

    Args:
        name (str): The name value pass to the `cargo_build_script` wrapper.

    Returns:
        str: A cleaned up name for a build script target.
    """
    if name.endswith("_bs"):
        return name[:-len("_bs")]
    return name

def _cargo_dep_env_implementation(ctx):
    empty_file = ctx.actions.declare_file(ctx.label.name + ".empty_file")
    empty_dir = ctx.actions.declare_directory(ctx.label.name + ".empty_dir")
    ctx.actions.write(
        output = empty_file,
        content = "",
    )
    ctx.actions.run(
        outputs = [empty_dir],
        executable = "true",
    )

    build_infos = []
    out_dir = ctx.file.out_dir
    if out_dir:
        if not out_dir.is_directory:
            fail("out_dir must be a directory artifact")

        # BuildInfos in this list are collected up for all transitive cargo_build_script
        # dependencies. This is important for any flags set in `dep_env` which reference this
        # `out_dir`.
        #
        # TLDR: This BuildInfo propagates up build script dependencies.
        build_infos.append(BuildInfo(
            dep_env = empty_file,
            flags = empty_file,
            linker_flags = empty_file,
            link_search_paths = empty_file,
            out_dir = out_dir,
            rustc_env = empty_file,
            compile_data = depset([]),
        ))
    return [
        DefaultInfo(files = depset(ctx.files.src)),
        # Parts of this BuildInfo is used when building all transitive dependencies
        # (cargo_build_script and otherwise), alongside the DepInfo. This is how other rules
        # identify this one as a valid dependency, but we don't otherwise have a use for it.
        #
        # TLDR: This BuildInfo propagates up normal (non build script) depenencies.
        #
        # In the future, we could consider setting rustc_env here, and also propagating dep_dir
        # so files in it can be referenced there.
        BuildInfo(
            dep_env = empty_file,
            flags = empty_file,
            linker_flags = empty_file,
            link_search_paths = empty_file,
            out_dir = None,
            rustc_env = empty_file,
            compile_data = depset([]),
        ),
        # Information here is used directly by dependencies, and it is an error to have more than
        # one dependency which sets this. This is the main way to specify information from build
        # scripts, which is what we're looking to do.
        DepInfo(
            dep_env = ctx.file.src,
            direct_crates = depset(),
            link_search_path_files = depset(),
            transitive_build_infos = depset(direct = build_infos),
            transitive_crate_outputs = depset(),
            transitive_crates = depset(),
            transitive_noncrates = depset(),
        ),
    ]

cargo_dep_env = rule(
    implementation = _cargo_dep_env_implementation,
    doc = (
        "A rule for generating variables for dependent `cargo_build_script`s " +
        "without a build script. This is useful for using Bazel rules instead " +
        "of a build script, while also generating configuration information " +
        "for build scripts which depend on this crate."
    ),
    attrs = {
        "out_dir": attr.label(
            doc = dedent("""\
                Folder containing additional inputs when building all direct dependencies.

                This has the same effect as a `cargo_build_script` which prints
                puts files into `$OUT_DIR`, but without requiring a build script.
            """),
            allow_single_file = True,
            mandatory = False,
        ),
        "src": attr.label(
            doc = dedent("""\
                File containing additional environment variables to set for build scripts of direct dependencies.

                This has the same effect as a `cargo_build_script` which prints
                `cargo:VAR=VALUE` lines, but without requiring a build script.

                This files should  contain a single variable per line, of format
                `NAME=value`, and newlines may be included in a value by ending a
                line with a trailing back-slash (`\\\\`).
            """),
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
