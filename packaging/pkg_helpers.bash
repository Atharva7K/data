#!/usr/bin/env bash
# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the BSD-style license found in the
# LICENSE file in the root directory of this source tree.

# A set of useful bash functions for common functionality we need to do in
# many build scripts


# Setup CUDA environment variables, based on CU_VERSION
#
# Inputs:
#   CU_VERSION (cpu, cu92, cu100)
#   NO_CUDA_PACKAGE (bool)
#   BUILD_TYPE (conda, wheel)
#
# Outputs:
#   VERSION_SUFFIX (e.g., "")
#   PYTORCH_VERSION_SUFFIX (e.g., +cpu)
#   WHEEL_DIR (e.g., cu100/)
#   CUDA_HOME (e.g., /usr/local/cuda-9.2, respected by torch.utils.cpp_extension)
#   FORCE_CUDA (respected by torchvision setup.py)
#   NVCC_FLAGS (respected by torchvision setup.py)
#
# Precondition: CUDA versions are installed in their conventional locations in
# /usr/local/cuda-*
#
# NOTE: Why VERSION_SUFFIX versus PYTORCH_VERSION_SUFFIX?  If you're building
# a package with CUDA on a platform we support CUDA on, VERSION_SUFFIX ==
# PYTORCH_VERSION_SUFFIX and everyone is happy.  However, if you are building a
# package with only CPU bits (e.g., torchaudio), then VERSION_SUFFIX is always
# empty, but PYTORCH_VERSION_SUFFIX is +cpu (because that's how you get a CPU
# version of a Python package.  But that doesn't apply if you're on OS X,
# since the default CU_VERSION on OS X is cpu.
setup_cuda() {

  # First, compute version suffixes.  By default, assume no version suffixes
  export VERSION_SUFFIX=""
  export PYTORCH_VERSION_SUFFIX=""
  export WHEEL_DIR="cpu/"
  # Wheel builds need suffixes (but not if they're on OS X, which never has suffix)
  if [[ "$BUILD_TYPE" == "wheel" ]] && [[ "$(uname)" != Darwin ]]; then
    # The default CUDA has no suffix
    if [[ "$CU_VERSION" != "cu100" ]]; then
      export PYTORCH_VERSION_SUFFIX="+$CU_VERSION"
    fi
    # Match the suffix scheme of pytorch, unless this package does not have
    # CUDA builds (in which case, use default)
    if [[ -z "$NO_CUDA_PACKAGE" ]]; then
      export VERSION_SUFFIX="$PYTORCH_VERSION_SUFFIX"
      # If the suffix is non-empty, we will use a wheel subdirectory
      if [[ -n "$PYTORCH_VERSION_SUFFIX" ]]; then
        export WHEEL_DIR="$PYTORCH_VERSION_SUFFIX/"
      fi
    fi
  fi

  # Now work out the CUDA settings
  case "$CU_VERSION" in
    cu100)
      export CUDA_HOME=/usr/local/cuda-10.0/
      export FORCE_CUDA=1
      # Hard-coding gencode flags is temporary situation until
      # https://github.com/pytorch/pytorch/pull/23408 lands
      export NVCC_FLAGS="-gencode=arch=compute_35,code=sm_35 -gencode=arch=compute_50,code=sm_50 -gencode=arch=compute_60,code=sm_60 -gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_75,code=sm_75 -gencode=arch=compute_50,code=compute_50"
      ;;
    cu92)
      export CUDA_HOME=/usr/local/cuda-9.2/
      export FORCE_CUDA=1
      export NVCC_FLAGS="-gencode=arch=compute_35,code=sm_35 -gencode=arch=compute_50,code=sm_50 -gencode=arch=compute_60,code=sm_60 -gencode=arch=compute_70,code=sm_70 -gencode=arch=compute_50,code=compute_50"
      ;;
    cpu)
      ;;
    *)
      echo "Unrecognized CU_VERSION=$CU_VERSION"
      exit 1
      ;;
  esac
}

# Populate build version if necessary, and add version suffix
#
# Inputs:
#   VERSION_SUFFIX (e.g., +cpu)
#
# Outputs:
#   BUILD_VERSION (e.g., 0.3.0.dev20220314+cpu)
setup_build_version() {
  version=$(head -1 "$SOURCE_ROOT_DIR/version.txt")
  if [[ $version == *a0 ]]; then
    len=$((${#version}-2))
    version=${version::$len}
  fi
  if [[ -z "$PYTORCH_VERSION" ]]; then
    # Nightly
    export BUILD_VERSION="$version.dev$(date "+%Y%m%d")$VERSION_SUFFIX"
    export UPLOAD_CHANNEL="nightly"
  else
    # Release
    export BUILD_VERSION="$version$VERSION_SUFFIX"
    export UPLOAD_CHANNEL="test"
  fi
}

# Set some useful variables for OS X, if applicable
setup_macos() {
  if [[ "$(uname)" == Darwin ]]; then
    export MACOSX_DEPLOYMENT_TARGET=10.9 CC=clang CXX=clang++
  fi
}

# Top-level entry point for things every package will need to do
setup_env() {
  setup_cuda
  setup_build_version
  setup_macos
}

# Function to retry functions that sometimes timeout or have flaky failures
retry () {
    $*  || (sleep 1 && $*) || (sleep 2 && $*) || (sleep 4 && $*) || (sleep 8 && $*)
}

# Install with pip a bit more robustly than the default
pip_install() {
  retry pip install --progress-bar off "$@"
}

# Install torch with pip, respecting PYTORCH_VERSION, and record the installed
# version into PYTORCH_VERSION, if applicable
setup_pip_pytorch_version() {
  if [[ -z "$PYTORCH_VERSION" ]]; then
    # Install latest prerelease version of torch, per our nightlies, consistent
    # with the requested cuda version
    pip_install --pre torch -f "https://download.pytorch.org/whl/nightly/${WHEEL_DIR}torch_nightly.html"
    # CUDA and CPU are ABI compatible on the CPU-only parts, so strip
    # in this case
    export PYTORCH_VERSION="$(pip show torch | grep ^Version: | sed 's/Version:  *//' | sed 's/+.\+//')"
  else
    pip_install "torch==$PYTORCH_VERSION$PYTORCH_VERSION_SUFFIX" \
      -f https://download.pytorch.org/whl/torch_stable.html \
      -f "https://download.pytorch.org/whl/${UPLOAD_CHANNEL}/torch_${UPLOAD_CHANNEL}.html"
  fi
}

# Fill PYTORCH_VERSION with the latest conda nightly version, and
# CONDA_CHANNEL_FLAGS with appropriate flags to retrieve these versions
#
# You MUST have populated PYTORCH_VERSION_SUFFIX before hand.
setup_conda_pytorch_constraint() {
  CONDA_CHANNEL_FLAGS=${CONDA_CHANNEL_FLAGS:-}
  if [[ -z "$PYTORCH_VERSION" ]]; then
    export CONDA_CHANNEL_FLAGS="${CONDA_CHANNEL_FLAGS} -c pytorch-nightly"
    export PYTORCH_VERSION="$(conda search --json 'pytorch[channel=pytorch-nightly]' | python -c "import sys, json, re; print(re.sub(r'\\+.*$', '', json.load(sys.stdin)['pytorch'][-1]['version']))")"
  else
    export CONDA_CHANNEL_FLAGS="${CONDA_CHANNEL_FLAGS} -c pytorch -c pytorch-${UPLOAD_CHANNEL}"
  fi
  if [[ "$CU_VERSION" == cpu ]]; then
    export CONDA_PYTORCH_BUILD_CONSTRAINT="- pytorch==$PYTORCH_VERSION${PYTORCH_VERSION_SUFFIX}"
    export CONDA_PYTORCH_CONSTRAINT="- pytorch==$PYTORCH_VERSION"
  else
    export CONDA_PYTORCH_BUILD_CONSTRAINT="- pytorch==${PYTORCH_VERSION}${PYTORCH_VERSION_SUFFIX}"
    export CONDA_PYTORCH_CONSTRAINT="- pytorch==${PYTORCH_VERSION}${PYTORCH_VERSION_SUFFIX}"
  fi
}
