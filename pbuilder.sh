#!/bin/bash
#
# Script ease building Debian packages

set -e

# Helper functions
load_var() {
  local i
  for i in ${PBUILDERRC_FILES}; do
    if [ -f "$i" ]; then
      eval `grep "^$1" $i`
    fi
  done
}
usage() {
  cat <<EOF
USAGE: $0 [-haiswS] subcommand

OPTIONS:
  -h help
  -a amd64
  -i i386
  -s squeeze
  -w wheezy
  -S sid

SUBCOMMAND:
  create
  update
  login [--save-after-login]
  build|gbp [src_dir ...]
  post-build
  repo
  log [pattern]
  commit
  push
  tag
  watch list_file
  staging
  new-patch
EOF
  exit 1
}

# Global settings
PBUILDERRC_FILES="/etc/pbuilderrc ~/.pbuilderrc"
# git-pbuilder
load_var REPO_BASE
load_var COWBUILDER_BASE
# reprepro
REPREPRO_BASE_DIR="${REPO_BASE}/reprepro"
REPREPRO_STAGING_DIR="${REPO_BASE}/reprepro-staging"
load_var BUILDRESULT
# other
DEFAULT_DISTS="squeeze wheezy"
DEFAULT_ARCHS="amd64 i386"

# Options
DISTS=""
ARCHS=""
OPTIND=1
while getopts "haiswS" opt; do
  case "$opt" in
    h) usage ;;
    a) ARCHS="$ARCHS amd64" ;;
    i) ARCHS="$ARCHS i386" ;;
    s) DISTS="$DISTS squeeze" ;;
    w) DISTS="$DISTS wheezy" ;;
    S) DISTS="$DISTS sid" ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

# Set default if empty
DISTS=${DISTS:-$DEFAULT_DISTS}
ARCHS=${ARCHS:-$DEFAULT_ARCHS}

# Sort DISTS and ARCHS, workaround for reprepro missing *.orig.tar.gz when
# processincoming
DISTS=`echo $DISTS | tr " " "\n" | sort | tr "\n" " "`
ARCHS=`echo $ARCHS | tr " " "\n" | sort | tr "\n" " "`

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $@" >&2
}

# Run command in tmux panes, and pause after finish
tmux_run() {
  tmux split-window -d "$@; echo; read -p '#### finished ####' tmp"
  tmux select-layout even-vertical >& /dev/null
}

# Kill other tmux panes
kp() {
  tmux kill-pane -a
}

# Exit if not inside debian source dir
check_dir() {
  if [ ! -f "debian/changelog" ]; then
    err "Please run inside debian source dir."
    exit 1
  fi
}

# Init build host env
prepare() {
  ln -s ${REPO_BASE}/gbp.conf ~/.gbp.conf
  ln -s ${REPO_BASE}/pbuilderrc ~/.pbuilderrc
  sudo apt-get install git-buildpackage cowbuilder reprepro bsd-mailx sudo tmux
}

# Update/create/login
ucl() {
  action="$1"
  shift
  if [ -f "$HOME/.pbuilderrc" ]; then
    GIT_PBUILDER_OPTIONS="--configfile $HOME/.pbuilderrc"
  fi
  for DIST in ${DISTS}; do
    load_var OTHERMIRROR
    for ARCH in ${ARCHS}; do
      # cowbuilder will not install extrapackages when creating .cow,
      # run `update' after `create' to get extrapackages installed
      if [ x"$action" == x"create" ]; then
        tmux_run "DIST=${DIST} ARCH=${ARCH} COWBUILDER_BASE=${COWBUILDER_BASE} \
          GIT_PBUILDER_OPTIONS='${GIT_PBUILDER_OPTIONS}' \
          git-pbuilder create --othermirror '$OTHERMIRROR' $*; \
          DIST=${DIST} ARCH=${ARCH} COWBUILDER_BASE=${COWBUILDER_BASE} \
          GIT_PBUILDER_OPTIONS='${GIT_PBUILDER_OPTIONS}' \
          git-pbuilder update"
      else
        tmux_run "DIST=${DIST} ARCH=${ARCH} COWBUILDER_BASE=${COWBUILDER_BASE} \
          GIT_PBUILDER_OPTIONS='${GIT_PBUILDER_OPTIONS}' \
          git-pbuilder ${action} --othermirror '$OTHERMIRROR' $*"
      fi
    done
  done
}

download() {
  git-import-dsc --download "$@"
}

# New changelog
nc() {
  check_dir
  branch=$(git rev-parse --abbrev-ref HEAD)
  version=$(dpkg-parsechangelog | awk '/^Version: / {print $2}')
  if echo ${version} | grep -q "${branch}[0-9]*$"; then
    git-dch --release
  else
    git-dch --release --new-version="${version}+${branch}1"
  fi
  version=$(dpkg-parsechangelog | awk '/^Version: / {print $2}')
  git add debian/changelog && git commit -m "debian/changelog: $version"
}

# New patch
np() {
  gbp-pq export
  git checkout -- debian/patches/
  num_patches=`cat debian/patches/series | wc -l`
  pushd debian/patches >& /dev/null
  for i in *.patch; do
    if [[ ${i:0:4} =~ ^[0-9]+$ ]] && [ ${i:0:4} -gt $num_patches ]; then
      git add $i
      echo $i >> series
      git add series
      tmp=${i:5}
      msg=${tmp/%.patch/}
      git commit -m "debian/patches/: $msg"
    fi
  done
  popd >& /dev/null
  git clean -f
}

clean() {
  check_dir
  if [ $(git status --porcelain | wc -l) -eq 0 ]; then 
    return
  fi
  if [ x"$1" == x"ask" ]; then
    git status --porcelain
    read -p "Clear git working tree?(Ctrl-C to cancel)" tmp
  fi
  git reset --hard HEAD && git clean -df
}

# Build
build() {
  check_dir
  NCPU=$(grep "^processor" /proc/cpuinfo | wc -l)
  # only build in one ARCH for source which only has `Architecture: all' packages
  if [ x"$(cat debian/control |grep '^Architecture:' | grep -v all)" == x ]; then
    err "Architecture: all, build only once per DIST."
    ARCHS=$(echo ${ARCHS} | awk '{print $1}')
  fi
  inc_orig="-sa"
  for DIST in ${DISTS}; do
    bin_only=""
    for ARCH in ${ARCHS}; do
      tmux_run "DEB_BUILD_OPTIONS='nocheck parallel=$((NCPU/2))' \
        COWBUILDER_BASE=${COWBUILDER_BASE} time -p git-buildpackage \
        --git-export-dir='../build_${DIST}_${ARCH}' \
        --git-dist=${DIST} --git-arch=${ARCH} \
        ${inc_orig} ${bin_only} $*"
      inc_orig="-sd"
      bin_only="-b"
    done
  done
}

build_all() {
  SOURCE=`dpkg-parsechangelog | awk '/^Source: / {print $2}'`
  VERSION=`dpkg-parsechangelog | awk '/^Version: / {print $2}'`
  jobidx=1
  failed=0
  pidlist=""
  inc_orig="--debbuildopts -sa"
  echo "+++ start building, see ../*.build for log +++"
  for i in $DISTS
  do
    build_bin_only=""
    for j in $ARCHS
    do
      echo "[$jobidx] building for $i $j"
      PDEBUILD="pdebuild --logfile ../${SOURCE}_${VERSION}_${DATE}_${i}_${j}.build $inc_orig $build_bin_only"
      if [ x"$action" = x"gbp" ]; then
        DIST=$i ARCH=$j DEB_BUILD_OPTIONS="nocheck parallel=$((NCPU/2))" git-buildpackage --git-submodules --git-ignore-new --git-builder="$PDEBUILD" --git-cleaner='/bin/true' >&/dev/null &
        pidlist="$pidlist $!"
      else
        DIST=$i ARCH=$j $PDEBUILD >&/dev/null &
        pidlist="$pidlist $!"
      fi
      inc_orig=""
      build_bin_only="-- --binary-arch"
      let "jobidx+=1"
      sleep 5
    done
  done

  jobidx=1
  for job in $pidlist
  do
    echo -n "waiting job [$jobidx]..."
    if wait $job; then
      echo "success"
    else
      let "failed+=1"
      echo "failed"
    fi
    let "jobidx+=1"
  done

  if [ $failed -gt 0 ]; then
    echo "$failed build(s) failed, please check build log"
    return 1
  fi
}

staging() {
  mkdir -p ${PBUILDER_RESULT_DIR}/staging
  cp ${PBUILDER_RESULT_DIR}/* ${PBUILDER_RESULT_DIR}/staging || true
  reprepro -b ${REPREPRO_STAGING_DIR} processincoming default
}

repo() {
  for i in $DISTS
  do
    reprepro gensnapshot $i prev
  done
  reprepro processincoming default
  for i in $DISTS
  do
    reprepro gensnapshot $i $DATE
  done
}

tag() {
  git-buildpackage --git-ignore-new --git-tag-only
}

post-build() {
  echo "+++ installing build results +++"
  repo
  echo "+++ git clean up +++"
  clean
  echo "+++ git taging +++"
  tag
}

push() {
  git push
  git push --tags
}

log() {
  pattern="*.build"
  if [ -n $1 ]; then
    pattern="*${1}*.build"
  fi
  pager `ls -t $pattern ../$pattern | head -n1`
}

watch() {
  # source_pkg_name local_dist debian_dist
  if [ x"$1" = x"" ]; then
    usage
  else
    watch_list=$1
  fi
  cat $watch_list | grep -v '^#' | while read debian_source local_dist debian_dist
  do
    local_version=`reprepro --list-format '${version}' listfilter $local_dist '$Source (== '$debian_source'), $Architecture (==source)'`
    if [ x"$debian_dist" = x"" ]; then
      debian_dist=$local_dist
    fi
    debian_version=`curl -s http://packages.debian.org/source/${debian_dist}/${debian_source} | grep "Source Package: ${debian_source}" | awk -F'(\(|\))' '{print $2}'`
    if [ x"$debian_version" != x"" ]; then
      if dpkg --compare-versions "$debian_version" gt "$local_version" || [ x"$DEBUG" != x"" ]; then
        echo "${debian_source}: debian(${debian_dist} ${debian_version}) local(${local_dist} ${local_version})"
      fi
    else
      echo "${debian_source}: can't get upstream version"
    fi
  done
}

action="$1"
case "$action" in
update|create|login)
  ucl "$@"
  ;;
build)
  shift
  if [ $# -gt 0 ]; then
    for dir in $@
    do
      if [ -d "$dir" ]; then
        pushd "$dir"
        build
        popd
      fi
    done
  else
    build
  fi
  ;;
*)
  if [ x$(type -t $action) == x"function" ]; then
    shift
    $action "$@"
  else
    usage
  fi
  ;;
esac
