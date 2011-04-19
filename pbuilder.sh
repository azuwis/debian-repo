#!/bin/bash
set -e
if [ x"$DISTS" = x ]; then
	DISTS="squeeze lenny"
fi
if [ x"$ARCHS" = x ]; then
	ARCHS="amd64 i386"
fi

case "$1" in
	create | update)
		for i in $DISTS
		do
			for j in $ARCHS
			do
				sudo DIST=$i ARCH=$j pbuilder $1
			done
		done
		;;
	build | gbp)
		inc_orig="--debbuildopts -sa"
		for i in $DISTS
		do
			build_bin_only=""
			for j in $ARCHS
			do
				if [ x"$1" = x"gbp" ]; then
					DIST=$i ARCH=$j git-buildpackage --git-ignore-new --git-builder="pdebuild $inc_orig $build_bin_only" --git-cleaner="/bin/true"
				else
					DIST=$i ARCH=$j pdebuild $inc_orig $build_bin_only
				fi
				inc_orig=""
				build_bin_only="-- --binary-arch"
				reprepro -b /srv/debian-repo/reprepro processincoming default
			done
		done
		;;
	*)
		echo "Usage: $0 {create|update|build|gbp}"
		exit 1
		;;
esac
