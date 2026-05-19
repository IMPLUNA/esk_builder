set shell := ["bash", "-euo", "pipefail", "-c"]

alias b := build
alias f := fmt
alias g := generic
alias gd := git-diff
alias gl := git-log
alias gs := git-status
alias gsh := git-show
alias x := xaga

default:
    @just --list

fmt:
    git ls-files -z '*.sh' | xargs -0r shfmt -w -i 4 -ci -bn -sr

fmt-check:
    git ls-files -z '*.sh' | xargs -0r shfmt -d -i 4 -ci -bn -sr

bash-check:
    git ls-files -z '*.sh' | xargs -0r bash -n

lint:
    git ls-files -z '*.sh' | xargs -0r shellcheck -x

py-lint:
    cd py && uv run ruff check src pyproject.toml

py-check:
    cd py && uv run python -m basedpyright src

check: fmt-check bash-check lint py-lint py-check

git-status:
    git status --short --branch

git-diff *args:
    git diff {{args}}

git-log limit="20":
    git log --oneline --decorate --graph -n {{limit}}

git-show ref="HEAD":
    git show --stat --patch {{ref}}

build *args:
    env {{args}} ./build.sh

xaga *args:
    env BUILD_TARGET=xaga {{args}} ./build.sh

generic *args:
    env BUILD_TARGET=generic {{args}} ./build.sh

# Build with Baseband Guard enabled
xaga-bbg *args:
    env BUILD_TARGET=xaga BBG=true {{args}} ./build.sh

generic-bbg *args:
    env BUILD_TARGET=generic BBG=true {{args}} ./build.sh

# Build with BBR v3 network optimization
xaga-bbr *args:
    env BUILD_TARGET=xaga BBR_V3=true {{args}} ./build.sh

generic-bbr *args:
    env BUILD_TARGET=generic BBR_V3=true {{args}} ./build.sh

# Build with all security features (KSU + SUSFS + KPM + BBG + BBR v3)
xaga-full *args:
    env BUILD_TARGET=xaga KSU=true SUSFS=true KPM=true BBG=true BBR_V3=true {{args}} ./build.sh

generic-full *args:
    env BUILD_TARGET=generic KSU=true SUSFS=true KPM=true BBG=true BBR_V3=true {{args}} ./build.sh

clean:
    rm -rf out work staged boot_image build.log github.json
