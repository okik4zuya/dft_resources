#!/bin/bash
# =============================================================================
# DFT Environment Setup — RunPod Instance
# Quantum ESPRESSO 7.3.1 + pseudopotentials (SSSP) + Python utilities
# Target material: SnO2-x / N-TiO2 (DFT+U, supercell, projected DOS)
# Run once on every new instance: bash setup_dft_env.sh
# =============================================================================

set -eo pipefail   # Note: no -u — avoids unbound variable false positives

# --- Colours for output -------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Config -------------------------------------------------------------
QE_VERSION="7.3.1"
QE_TAG="qe-${QE_VERSION}"
QE_SRC_DIR="/opt/qe-${QE_VERSION}"
QE_BUILD_DIR="${QE_SRC_DIR}/build"
QE_BIN_DIR="${QE_SRC_DIR}/bin"

# Canonical source: GitLab (GitHub mirror only has up to v7.0)
# Strategy: git clone --depth 1 at the release tag — no tarball URL needed.
QE_GITLAB_URL="https://gitlab.com/QEF/q-e.git"

WORKSPACE="${WORKSPACE:-/workspace}"
CASES_DIR="${WORKSPACE}/cases"
PSEUDO_DIR="${WORKSPACE}/pseudo"
SCRIPTS_DIR="${WORKSPACE}/scripts"
LOGS_DIR="${WORKSPACE}/logs"

# SSSP pseudopotential library (efficiency set — PBE, suitable for DFT+U)
SSSP_URL="https://archive.materialscloud.org/record/file?filename=SSSP_1.3.0_PBE_efficiency.tar.gz&record_id=1863"
SSSP_TARBALL="SSSP_1.3.0_PBE_efficiency.tar.gz"

# Number of parallel make jobs — use all available cores
NPROC=$(nproc)

# ========================================================================
echo ""
echo "============================================================"
echo "  DFT Environment Setup — Quantum ESPRESSO ${QE_VERSION}"
echo "  $(date)"
echo "============================================================"
echo ""

# --- 1. System update ---------------------------------------------------
info "Updating apt package lists..."
apt-get update -qq

# --- 2. Core system utilities -------------------------------------------
info "Installing core system utilities..."
apt-get install -y --no-install-recommends \
    curl wget git vim htop screen tmux \
    python3-pip python3-venv \
    bc ca-certificates gnupg \
    unzip tar gzip 2>/dev/null

# --- 3. Build toolchain -------------------------------------------------
# On Ubuntu 22.04, ScaLAPACK has MPI-flavour-specific packages.
# libscalapack-mpi-dev is a meta-package that may not pull the OpenMPI
# variant; libscalapack-openmpi-dev installs the correct .so explicitly.
# QE's CMake also cannot auto-detect the non-standard library name
# (libscalapack-openmpi.so), so SCALAPACK_LIBRARIES is passed manually
# in the cmake invocation below.
info "Installing build toolchain (gfortran, OpenMPI, FFTW, LAPACK, ScaLAPACK)..."
apt-get install -y --no-install-recommends \
    build-essential \
    gfortran \
    cmake \
    ninja-build \
    libopenmpi-dev \
    openmpi-bin \
    libfftw3-dev \
    libfftw3-mpi-dev \
    liblapack-dev \
    libblas-dev \
    libscalapack-openmpi-dev \
    || error "Build toolchain installation failed."

info "Build toolchain installed."

# Resolve the ScaLAPACK library path for CMake.
# On Ubuntu 22 with OpenMPI the .so is named libscalapack-openmpi.so,
# not libscalapack.so, so CMake's FindSCALAPACK cannot find it on its own.
SCALAPACK_LIB=$(find /usr/lib -name "libscalapack-openmpi.so" 2>/dev/null | head -1)
if [ -z "${SCALAPACK_LIB}" ]; then
    warn "libscalapack-openmpi.so not found — ScaLAPACK will be disabled."
    SCALAPACK_FLAGS="-DQE_ENABLE_SCALAPACK=OFF"
else
    info "ScaLAPACK library found: ${SCALAPACK_LIB}"
    SCALAPACK_FLAGS="-DQE_ENABLE_SCALAPACK=ON -DSCALAPACK_LIBRARIES=${SCALAPACK_LIB}"
fi

# --- 4. Clone Quantum ESPRESSO source from GitLab -----------------------
# The GitHub mirror (QEF/q-e) only hosts up to v7.0.
# All releases from v7.1 onward live exclusively on GitLab.
# --depth 1 fetches only the tagged commit — fast (~200 MB, no full history).
# --recurse-submodules pulls external libraries needed by CMake.
if [ -d "${QE_SRC_DIR}/.git" ]; then
    warn "QE source already cloned at ${QE_SRC_DIR} — skipping clone."
else
    info "Cloning Quantum ESPRESSO ${QE_VERSION} from GitLab (shallow, tag ${QE_TAG})..."
    git clone --depth 1 \
        --branch "${QE_TAG}" \
        --recurse-submodules \
        --shallow-submodules \
        "${QE_GITLAB_URL}" \
        "${QE_SRC_DIR}" \
        || error "git clone failed. Check network access to gitlab.com."
    info "QE source cloned to ${QE_SRC_DIR}."
fi

# --- 5. Compile Quantum ESPRESSO ----------------------------------------
# -DQE_ENABLE_SCALAPACK     → parallel diagonalisation (set dynamically above)
# -DSCALAPACK_LIBRARIES     → explicit path, bypasses broken auto-detection
# -DQE_ENABLE_OPENMP=OFF    → pure MPI parallelism; OMP causes issues on cloud VMs
# -DQE_ENABLE_HDF5=OFF      → not needed for standard SCF/bands/DOS calculations
if [ -f "${QE_BIN_DIR}/pw.x" ]; then
    warn "pw.x already found at ${QE_BIN_DIR}/pw.x — skipping compilation."
else
    info "Configuring QE build with CMake (this takes ~5–15 min on first run)..."
    mkdir -p "${QE_BUILD_DIR}"
    cmake -S "${QE_SRC_DIR}" -B "${QE_BUILD_DIR}" \
        -DCMAKE_Fortran_COMPILER=mpif90 \
        -DCMAKE_C_COMPILER=mpicc \
        -DQE_ENABLE_MPI=ON \
        ${SCALAPACK_FLAGS} \
        -DQE_ENABLE_OPENMP=OFF \
        -DQE_ENABLE_HDF5=OFF \
        -DCMAKE_INSTALL_PREFIX="${QE_SRC_DIR}" \
        || error "CMake configuration failed."

    info "Compiling QE with ${NPROC} parallel jobs..."
    cmake --build "${QE_BUILD_DIR}" -j"${NPROC}" \
        || error "QE compilation failed. Check build logs in ${QE_BUILD_DIR}."

    info "Installing QE binaries to ${QE_BIN_DIR}..."
    cmake --install "${QE_BUILD_DIR}" \
        || error "QE installation step failed."

    info "Quantum ESPRESSO ${QE_VERSION} compiled and installed."
fi

# --- 6. Add QE to PATH in .bashrc ---------------------------------------
QE_PATH_LINE="export PATH=${QE_BIN_DIR}:\$PATH"
if grep -qF "${QE_BIN_DIR}" ~/.bashrc; then
    warn "QE already in PATH in ~/.bashrc — skipping."
else
    echo ""                                   >> ~/.bashrc
    echo "# Quantum ESPRESSO ${QE_VERSION}"  >> ~/.bashrc
    echo "${QE_PATH_LINE}"                   >> ~/.bashrc
    info "QE bin directory added to PATH in ~/.bashrc."
fi

# --- 7. Environment variables -------------------------------------------
# PSEUDO_DIR          : referenced in every QE input file as pseudo_dir
# OMP_NUM_THREADS     : =1 disables threading; MPI handles all parallelism
# OMPI_ALLOW_RUN_AS_ROOT / _CONFIRM : RunPod containers run as root;
#   OpenMPI refuses to start without these two variables set.
PSEUDO_ENV_LINE="export PSEUDO_DIR=${PSEUDO_DIR}"
OMP_ENV_LINE="export OMP_NUM_THREADS=1"
OMPI_ROOT_LINE="export OMPI_ALLOW_RUN_AS_ROOT=1"
OMPI_ROOT_CONFIRM_LINE="export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1"

if grep -qF "PSEUDO_DIR" ~/.bashrc; then
    warn "PSEUDO_DIR already set in ~/.bashrc — skipping."
else
    echo "${PSEUDO_ENV_LINE}" >> ~/.bashrc
    info "PSEUDO_DIR set to ${PSEUDO_DIR} in ~/.bashrc."
fi

if grep -qF "OMP_NUM_THREADS" ~/.bashrc; then
    warn "OMP_NUM_THREADS already set in ~/.bashrc — skipping."
else
    echo "${OMP_ENV_LINE}" >> ~/.bashrc
    info "OMP_NUM_THREADS=1 set in ~/.bashrc."
fi

if grep -qF "OMPI_ALLOW_RUN_AS_ROOT" ~/.bashrc; then
    warn "OMPI root override already set in ~/.bashrc — skipping."
else
    echo "${OMPI_ROOT_LINE}"         >> ~/.bashrc
    echo "${OMPI_ROOT_CONFIRM_LINE}" >> ~/.bashrc
    info "OMPI root-as-root override set in ~/.bashrc (required for RunPod)."
fi

# --- 8. Python DFT utilities --------------------------------------------
# ase       : structure building, format conversion, k-path generation
# pymatgen  : QE output parsing, Materials Project queries, supercell tools
# seekpath  : automatic high-symmetry k-path (Γ–X–M–Γ) for band structure
# numpy, matplotlib, scipy, pandas : standard scientific stack
info "Installing Python DFT utilities..."
pip3 install --quiet --break-system-packages \
    --no-warn-script-location \
    numpy matplotlib scipy pandas \
    ase \
    pymatgen \
    seekpath \
    || warn "Some Python packages failed to install — check manually."

info "Python utilities installed."

# --- 9. Download SSSP pseudopotentials ----------------------------------
# SSSP 1.3.0 efficiency set, PBE functional.
# Covers all elements in SnO2-x / N-TiO2: Ti, O, Sn, N.
# Stored in PSEUDO_DIR on the persistent volume — survives pod restarts.
PSEUDO_COUNT=$(find "${PSEUDO_DIR}" -name "*.UPF" 2>/dev/null | wc -l)
if [ "${PSEUDO_COUNT}" -gt 0 ]; then
    warn "${PSEUDO_COUNT} UPF files already found in ${PSEUDO_DIR} — skipping download."
else
    if [ -d "${WORKSPACE}" ]; then
        mkdir -p "${PSEUDO_DIR}"
        info "Downloading SSSP 1.3.0 PBE efficiency pseudopotentials..."
        wget -q --show-progress \
            -O "/tmp/${SSSP_TARBALL}" \
            "${SSSP_URL}" \
            && {
                tar -xzf "/tmp/${SSSP_TARBALL}" -C "${PSEUDO_DIR}/" \
                    || warn "SSSP extraction failed — archive may be corrupt."
                rm -f "/tmp/${SSSP_TARBALL}"
                info "SSSP pseudopotentials extracted to ${PSEUDO_DIR}."
            } \
            || warn "SSSP download failed. Download manually from:
               https://www.materialscloud.org/discover/sssp
               and place UPF files in ${PSEUDO_DIR}."
    else
        warn "Persistent volume not found — pseudopotentials not downloaded."
        warn "Mount a volume at ${WORKSPACE} and re-run, or place UPF files manually."
    fi
fi

# --- 10. Persistent volume directory structure --------------------------
if [ -d "${WORKSPACE}" ]; then
    info "Setting up persistent volume directories at ${WORKSPACE}..."
    mkdir -p "${CASES_DIR}" "${PSEUDO_DIR}" "${SCRIPTS_DIR}" "${LOGS_DIR}"
    cp "$0" "${SCRIPTS_DIR}/setup_dft_env.sh" 2>/dev/null \
        && info "Script saved to ${SCRIPTS_DIR}/setup_dft_env.sh" \
        || warn "Could not copy script to persistent volume."
else
    warn "Persistent volume not found at ${WORKSPACE}."
    warn "Set WORKSPACE=/your/mount/path and re-run to configure directories."
fi

# --- 11. Smoke test -----------------------------------------------------
info "Verifying Quantum ESPRESSO install..."
export PATH="${QE_BIN_DIR}:$PATH"          # activate for this shell session only
export OMPI_ALLOW_RUN_AS_ROOT=1            # RunPod runs as root; required for mpirun
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1

if [ -f "${QE_BIN_DIR}/pw.x" ]; then
    info "pw.x found at ${QE_BIN_DIR}/pw.x ✓"
else
    warn "pw.x not found — run 'source ~/.bashrc && pw.x --version' to verify manually."
fi

# Check key executables for the SnO2-x / N-TiO2 workflow
for BIN in bands.x dos.x projwfc.x pp.x epsilon.x; do
    if [ -f "${QE_BIN_DIR}/${BIN}" ]; then
        info "${BIN} found ✓"
    else
        warn "${BIN} not found — may not have been built. Check CMake output."
    fi
done

# MPI sanity check
if command -v mpirun &>/dev/null; then
    info "mpirun available: $(mpirun --version 2>&1 | head -1) ✓"
else
    warn "mpirun not found in PATH — MPI parallel runs will not work."
fi

# Python ASE check
python3 -c "import ase; print('[INFO] ASE version:', ase.__version__)" 2>/dev/null \
    || warn "ASE import failed — check pip installation."

# --- 12. Summary --------------------------------------------------------
echo ""
echo "============================================================"
echo "  Setup complete — $(date)"
echo "============================================================"
echo ""
echo "  Quantum ESPRESSO : ${QE_VERSION}"
echo "  QE bin dir       : ${QE_BIN_DIR}"
echo "  ScaLAPACK        : ${SCALAPACK_LIB:-disabled}"
echo "  Pseudopotentials : ${PSEUDO_DIR}"
echo "  Cases dir        : ${CASES_DIR}"
echo ""
echo "  !! REQUIRED — activate environment in this terminal:"
echo ""
echo "      source ~/.bashrc"
echo ""
echo "  Then verify with:"
echo ""
echo "      pw.x --version"
echo "      mpirun -np 4 pw.x --version"
echo ""
echo "  Typical workflow for SnO2-x / N-TiO2:"
echo ""
echo "      1. pw.x       — SCF + geometry relaxation of doped supercell"
echo "      2. pw.x       — NSCF on dense k-grid"
echo "      3. bands.x + dos.x + projwfc.x  — band structure & PDOS"
echo "      4. pp.x       — charge density difference visualisation"
echo "      5. epsilon.x  — optical absorption spectrum"
echo ""
echo "  Pseudopotentials (SSSP PBE efficiency) are in:"
echo "      ${PSEUDO_DIR}"
echo "  Reference them in QE input files with:"
echo "      pseudo_dir = '${PSEUDO_DIR}'"
echo "============================================================"
