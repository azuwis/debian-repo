#!/bin/bash

export REPREPRO_BASE_DIR=/srv/debian-repo/reprepro
repo=reprepro

set -e
if [ x"$DISTS" = x ]; then
	DISTS="squeeze lenny"
fi
if [ x"$ARCHS" = x ]; then
	ARCHS="amd64 i386"
fi

build_all()
{
	inc_orig="--debbuildopts -sa"
	echo "+++ start building, see ../*.build for log +++"
	for i in $DISTS
	do
		build_bin_only=""
		for j in $ARCHS
		do
			echo "+++ building for $i $j +++"
			if [ x"$action" = x"gbp" ]; then
				DIST=$i ARCH=$j git-buildpackage --git-ignore-new --git-builder="pdebuild $inc_orig $build_bin_only" --git-cleaner='git reset --hard HEAD && git clean -df' >&/dev/null
			else
				DIST=$i ARCH=$j pdebuild $inc_orig $build_bin_only >&/dev/null
			fi
			echo "done"
			inc_orig=""
			build_bin_only="-- --binary-arch"
		done
	done
	repo
	git-buildpackage --git-ignore-new --git-tag-only
}

log()
{
	pattern="*.build"
	if [ -n $1 ]; then
		pattern="*${1}*.build"
	fi
	pager `ls -t ../$pattern | head -n1`
}

commit()
{
	git add debian/changelog && git commit -m "debian/changelog: $(dpkg-parsechangelog | awk '/^Version: / {print $2}')"
}

repo()
{
	repo_$repo
}

repo_debarchiver()
{
	if [ x"$1" = x"all" ]; then
		echo "updating all debs"
		debarchiver -so --scanall
	else
		echo "installing built results"
		debarchiver -so
	fi
}

repo_reprepro()
{
	for i in $DISTS
	do
		reprepro gensnapshot $i prev
	done
	reprepro processincoming default
	for i in $DISTS
	do
		reprepro gensnapshot $i `date +%Y%m%d%H%M%S`
	done
}

action=$1

case "$action" in
	create | update)
		for i in $DISTS
		do
			for j in $ARCHS
			do
				sudo DIST=$i ARCH=$j pbuilder $action
			done
		done
		;;
	build | gbp)
		shift
		if [ $# -gt 0 ]; then
			for dir in $@
			do
				if [ -d "$dir" ]; then
					pushd "$dir"
					build_all
					popd
				fi
			done
		else
			build_all
		fi
		;;
	*)
		if type $action | grep -q function; then
			shift
			$action "$@"
		else
			echo "Usage: $0 subcommand"
			echo "    create"
			echo "    update"
			echo "    build|gbp [src_dir ...]"
			echo "    repo [all]"
			echo "    log [pattern]"
			echo "    commit"
			exit 1
		fi
		;;
esac
