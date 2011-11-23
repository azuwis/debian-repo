#!/bin/bash
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
	update_repo
	git-buildpackage --git-ignore-new --git-tag-only
}

last_log()
{
	pager `ls -t ../*.build | head -n1`
}

update_repo()
{
	echo "installing built results"
	debarchiver -so
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
	update_repo)
		update_repo
		;;
	log)
		last_log
		;;
	*)
		echo "Usage: $0 {create|update|update_repo|build|gbp[src_dir ...]|log}"
		exit 1
		;;
esac
