#!/usr/bin/env bash

export CERTORA="/Users/krishan/Tools/certora-build"
export JAVA_HOME="/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
export PATH="$CERTORA:$JAVA_HOME/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/rustup/bin:/Users/krishan/.cargo/bin:/Users/krishan/.local/bin:/opt/homebrew/bin:$PATH"
source "/Users/krishan/Tools/CertoraProver/.venv/bin/activate"
