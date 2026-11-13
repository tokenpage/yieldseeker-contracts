#!/usr/bin/env bash

export CERTORA_PROVER_DIR="${CERTORA_PROVER_DIR:-$HOME/Tools/CertoraProver}"
export CERTORA="${CERTORA:-$HOME/Tools/certora-build}"
export JAVA_HOME="${CERTORA_JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export PATH="$CERTORA:$JAVA_HOME/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:$PATH"
source "$CERTORA_PROVER_DIR/.venv/bin/activate"
export CERTORA_DISABLE_POPUP=1
export CERTORA_DISABLE_NOTIFICATION=1
unset CERTORAKEY CI GITHUB_ACTIONS
