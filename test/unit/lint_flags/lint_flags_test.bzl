"""Unittest to verify compile_data (attribute) propagation"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest")
load("//rust:defs.bzl", "rust_clippy", "rust_doc", "rust_library", "rust_lint_config")
load("//cargo:defs.bzl", "extract_cargo_lints")
load("//test/unit:common.bzl", "assert_argv_contains", "assert_argv_contains_not")

def target_action_contains_not_flag(env, target, flags):
    for action in target.actions:
        if action.mnemonic == "Rustc":
            for flag in flags:
                assert_argv_contains_not(
                    env = env,
                    action = action,
                    flag = flag,
                )

def target_action_contains_flag(env, target, flags):
    for action in target.actions:
        if action.mnemonic == "Rustc":
            for flag in flags:
                assert_argv_contains(
                    env = env,
                    action = action,
                    flag = flag,
                )

def _extra_rustc_flags_present_test(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    target_action_contains_flag(env, target, ctx.attr.rustc_flags)

    # Check the exec configuration target does NOT contain.
    target = ctx.attr.lib_exec
    target_action_contains_not_flag(env, target, ctx.attr.rustc_flags)

    return analysistest.end(env)

extra_rustc_flag_present_test = analysistest.make(
    _extra_rustc_flags_present_test,
    attrs = {
        "lib_exec": attr.label(
            mandatory = True,
            cfg = "exec",
        ),
        "rustc_flags": attr.string_list(
            mandatory = True,
        ),
    },
)

def _define_test_targets_lint_config():
    rust_lint_config(
        name = "lint_config",
        rustc = {"unknown_lints": "allow"},
        rustc_check_cfg = {"bazel": []},
        clippy = {"box_default": "warn"},
        rustdoc = {"unportable_markdown": "deny"},
    )

    rust_library(
        name = "lib_lint_config",
        srcs = ["sub_project/lib.rs"],
        lint_config = ":lint_config",
        edition = "2021",
    )

    rust_clippy(
        name = "clippy_lint_config",
        deps = [":lib_lint_config"],
    )

    rust_doc(
        name = "docs_lint_config",
        crate = ":lib_lint_config",
    )

def _define_test_targets_cargo_lints():
    extract_cargo_lints(
        name = "sub_project_lints",
        manifest = "sub_project/Cargo.toml",
    )

    rust_library(
        name = "lib_cargo_lints",
        srcs = ["sub_project/lib.rs"],
        lint_config = ":sub_project_lints",
        edition = "2021",
    )

    rust_clippy(
        name = "clippy_cargo_lints",
        deps = [":lib_cargo_lints"],
    )

    rust_doc(
        name = "docs_cargo_lints",
        crate = ":lib_cargo_lints",
    )

def _define_test_targets_cargo_workspace_lints():
    extract_cargo_lints(
        name = "sub_project_workspace_lints",
        manifest = "sub_project_workspace/Cargo.toml",
        workspace = "Cargo.toml",
    )

    rust_library(
        name = "lib_cargo_workspace_lints",
        srcs = ["sub_project/lib.rs"],
        lint_config = ":sub_project_workspace_lints",
        edition = "2021",
    )

    rust_clippy(
        name = "clippy_cargo_workspace_lints",
        deps = [":lib_cargo_workspace_lints"],
    )

    rust_doc(
        name = "docs_cargo_workspace_lints",
        crate = ":lib_cargo_workspace_lints",
    )

def lint_flags_test_suite(name):
    """Entry-point macro called from the BUILD file.

    Args:
        name (str): Name of the macro.
    """

    # 1. Test extracting lints from a single project's Cargo.toml

    _define_test_targets_lint_config()

    extra_rustc_flag_present_test(
        name = "rustc_lints_apply_flags_lint_config",
        target_under_test = ":lib_lint_config",
        lib_exec = ":lib_lint_config",
        rustc_flags = [
            "--allow=unknown_lints",
            "--check-cfg=cfg(bazel)",
        ],
    )

    extra_rustc_flag_present_test(
        name = "clippy_lints_apply_flags_lint_config",
        target_under_test = ":clippy_lint_config",
        lib_exec = ":clippy_lint_config",
        rustc_flags = ["--warn=clippy::box_default"],
    )

    extra_rustc_flag_present_test(
        name = "rustdoc_lints_apply_flags_lint_config",
        target_under_test = ":docs_lint_config",
        lib_exec = ":docs_lint_config",
        rustc_flags = ["--deny=rustdoc::unportable_markdown"],
    )

    # 2. Test extracting lints from a single project's Cargo.toml

    _define_test_targets_cargo_lints()

    extra_rustc_flag_present_test(
        name = "rustc_lints_apply_flags_cargo_lints",
        target_under_test = ":lib_cargo_lints",
        lib_exec = ":lib_cargo_lints",
        rustc_flags = ["--warn=unknown_lints"],
    )

    extra_rustc_flag_present_test(
        name = "clippy_lints_apply_flags_cargo_lints",
        target_under_test = ":clippy_cargo_lints",
        lib_exec = ":clippy_cargo_lints",
        rustc_flags = ["--warn=clippy::box_default"],
    )

    extra_rustc_flag_present_test(
        name = "rustdoc_lints_apply_flags_cargo_lints",
        target_under_test = ":docs_cargo_lints",
        lib_exec = ":docs_cargo_lints",
        rustc_flags = ["--deny=rustdoc::unportable_markdown"],
    )

    # 3. Test extracting lints from a Cargo.toml that inherits from a Workspace.

    _define_test_targets_cargo_workspace_lints()

    extra_rustc_flag_present_test(
        name = "rustc_lints_apply_flags_cargo_workspace_lints",
        target_under_test = ":lib_cargo_workspace_lints",
        lib_exec = ":lib_cargo_workspace_lints",
        rustc_flags = ["--warn=unknown_lints"],
    )

    extra_rustc_flag_present_test(
        name = "clippy_lints_apply_flags_cargo_workspace_lints",
        target_under_test = ":clippy_cargo_workspace_lints",
        lib_exec = ":clippy_cargo_workspace_lints",
        rustc_flags = ["--warn=clippy::box_default"],
    )

    extra_rustc_flag_present_test(
        name = "rustdoc_lints_apply_flags_cargo_workspace_lints",
        target_under_test = ":docs_cargo_workspace_lints",
        lib_exec = ":docs_cargo_workspace_lints",
        rustc_flags = ["--deny=rustdoc::unportable_markdown"],
    )    

    native.test_suite(
        name = name,
        tests = [
            ":rustc_lints_apply_flags_lint_config",
            ":clippy_lints_apply_flags_lint_config",
            ":rustdoc_lints_apply_flags_lint_config",
            ":rustc_lints_apply_flags_cargo_lints",
            ":clippy_lints_apply_flags_cargo_lints",
            ":rustdoc_lints_apply_flags_cargo_lints",
            ":rustc_lints_apply_flags_cargo_workspace_lints",
            ":clippy_lints_apply_flags_cargo_workspace_lints",
            ":rustdoc_lints_apply_flags_cargo_workspace_lints",
        ],
    )
