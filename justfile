#!/usr/bin/env just --justfile

main_crate := 'serde_tuple'
features_flag := '--all-features'

# if running in CI, treat warnings as errors by setting RUSTFLAGS and RUSTDOCFLAGS to '-D warnings' unless they are already set
# Use `CI=true just ci-test` to run the same tests as in GitHub CI.
# Use `just env-info` to see the current values of RUSTFLAGS and RUSTDOCFLAGS
ci_mode := if env('CI', '') != '' {'1'} else {''}
export RUSTFLAGS := env('RUSTFLAGS', if ci_mode == '1' {'-D warnings'} else {''})
export RUSTDOCFLAGS := env('RUSTDOCFLAGS', if ci_mode == '1' {'-D warnings'} else {''})
export RUST_BACKTRACE := env('RUST_BACKTRACE', if ci_mode == '1' {'1'} else {''})

@_default:
    {{just_executable()}} --list

# Build the project
build:
    cargo build --workspace --all-targets {{features_flag}}

# Quick compile without building a binary
check:
    cargo check --workspace --all-targets {{features_flag}}

# Verify that the current version of the crate is not the same as the one published on crates.io
check-if-published package=main_crate:  (assert-cmd 'jq')
    #!/usr/bin/env bash
    set -euo pipefail
    LOCAL_VERSION="$({{just_executable()}} get-crate-field version package)"
    echo "Detected crate {{package}} version:  '$LOCAL_VERSION'"
    PUBLISHED_VERSION="$(cargo search --quiet {{package}} | grep "^{{package}} =" | sed -E 's/.* = "(.*)".*/\1/')"
    echo "Published crate version: '$PUBLISHED_VERSION'"
    if [ "$LOCAL_VERSION" = "$PUBLISHED_VERSION" ]; then
        echo "ERROR: The current crate version has already been published."
        exit 1
    else
        echo "The current crate version has not yet been published."
    fi

# Quick compile for MSRV, without compiling benches
check-msrv:
    cargo check --all-targets

# Generate code coverage report to upload to codecov.io
ci-coverage: env-info && \
            (coverage '--codecov --output-path target/llvm-cov/codecov.info')
    # ATTENTION: the full file path above is used in the CI workflow
    mkdir -p target/llvm-cov

# Run all tests as expected by CI
ci-test: env-info test-fmt clippy check test test-doc && assert-git-is-clean

# Run minimal subset of tests to ensure compatibility with MSRV
ci-test-msrv: env-info check-msrv test-msrv

# Clean all build artifacts
clean:
    cargo clean
    rm -f Cargo.lock

# Run cargo clippy to lint the code
clippy *args:
    cargo clippy --workspace --all-targets {{features_flag}} {{args}}

# Generate code coverage report. Will install `cargo llvm-cov` if missing.
coverage *args='--no-clean --open':  (cargo-install 'cargo-llvm-cov')
    cargo llvm-cov --workspace --all-targets {{features_flag}} --include-build-script {{args}}

# Build and open code documentation
docs *args='--open':
    DOCS_RS=1 cargo doc --no-deps {{args}} --workspace {{features_flag}}

# Print environment info
env-info:
    @echo "Running {{if ci_mode == '1' {'in CI mode'} else {'in dev mode'} }} on {{os()}} / {{arch()}}"
    {{just_executable()}} --version
    rustc --version
    cargo --version
    rustup --version
    @echo "RUSTFLAGS='$RUSTFLAGS'"
    @echo "RUSTDOCFLAGS='$RUSTDOCFLAGS'"

# Reformat all code `cargo fmt`. If nightly is available, use it for better results
fmt:
    #!/usr/bin/env bash
    set -euo pipefail
    if rustup component list --toolchain nightly | grep rustfmt &> /dev/null; then
        echo 'Reformatting Rust code using nightly Rust fmt to sort imports'
        cargo +nightly fmt --all -- --config imports_granularity=Module,group_imports=StdExternalCrate
    else
        echo 'Reformatting Rust with the stable cargo fmt.  Install nightly with `rustup install nightly` for better results'
        cargo fmt --all
    fi

# Get any package's field from the metadata
get-crate-field field package=main_crate:
    cargo metadata --format-version 1 | jq -r '.packages | map(select(.name == "{{package}}")) | first | .{{field}}'

# Get the minimum supported Rust version (MSRV) for the crate
get-msrv package=main_crate:  (get-crate-field 'rust_version' package)

# Find the minimum supported Rust version (MSRV) using cargo-msrv extension, and update Cargo.toml
msrv:  (cargo-install 'cargo-msrv')
    cargo msrv find --write-msrv --ignore-lockfile -- just ci-test-msrv

# Check semver compatibility with prior published version. Install it with `cargo install cargo-semver-checks`
semver *args:  (cargo-install 'cargo-semver-checks')
    cargo semver-checks {{features_flag}} {{args}}

# Run all tests
test:
    cargo test --workspace --all-targets {{features_flag}}
    cargo test --workspace --doc {{features_flag}}

# Test documentation generation
test-doc:  (docs '')

# Test code formatting
test-fmt:
    cargo fmt --all -- --check

# Run all tests for MSRV
test-msrv:
    cargo test --workspace

# Find unused dependencies. Install it with `cargo install cargo-udeps`
udeps:  (cargo-install 'cargo-udeps')
    cargo +nightly udeps --workspace --all-targets {{features_flag}}

# Update all dependencies, including breaking changes. Requires nightly toolchain (install with `rustup install nightly`)
update:
    cargo +nightly -Z unstable-options update --breaking
    cargo update

# Ensure that a certain command is available
[private]
assert-cmd command:
    @if ! type {{command}} > /dev/null; then \
        echo "Command '{{command}}' could not be found. Please make sure it has been installed on your computer." ;\
        exit 1 ;\
    fi

# Make sure the git repo has no uncommitted changes
[private]
assert-git-is-clean:
    @if [ -n "$(git status --untracked-files --porcelain)" ]; then \
      >&2 echo "ERROR: git repo is no longer clean. Make sure compilation and tests artifacts are in the .gitignore, and no repo files are modified." ;\
      >&2 echo "######### git status ##########" ;\
      git status ;\
      git --no-pager diff ;\
      exit 1 ;\
    fi

# Check if a certain Cargo command is installed, and install it if needed
[private]
cargo-install $COMMAND $INSTALL_CMD='' *args='':
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v $COMMAND > /dev/null; then
        if ! command -v cargo-binstall > /dev/null; then
            echo "$COMMAND could not be found. Installing it with    cargo install ${INSTALL_CMD:-$COMMAND} --locked {{args}}"
            cargo install ${INSTALL_CMD:-$COMMAND} --locked {{args}}
        else
            echo "$COMMAND could not be found. Installing it with    cargo binstall ${INSTALL_CMD:-$COMMAND} --locked {{args}}"
            cargo binstall ${INSTALL_CMD:-$COMMAND} --locked {{args}}
        fi
    fi
