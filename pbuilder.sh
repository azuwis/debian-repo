#!/bin/bash

export REPREPRO_BASE_DIR=/srv/debian-repo/reprepro

set -e
if [ x"$DISTS" = x ]; then
	DISTS="lenny squeeze"
fi
if [ x"$ARCHS" = x ]; then
	ARCHS="amd64 i386"
fi

# sort DISTS, workaround for reprepro missing *.orig.tar.gz when processincoming
DISTS=`echo $DISTS | tr " " "\n" | sort | tr "\n" " "`
ARCHS=`echo $ARCHS | tr " " "\n" | sort | tr "\n" " "`

DATE=`date +%Y%m%d%H%M%S`

NCPU=`grep "^processor" /proc/cpuinfo | wc -l`

build_all()
{
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

post-build()
{
	echo "+++ installing build results +++"
	repo
	echo "+++ git clean up +++"
	clean
	echo "+++ git taging +++"
	tag
}

clean()
{
	if [ -f debian/changelog ]; then
		git reset --hard HEAD && git clean -df
	else
		echo "skip clean, not in debian source dir"
	fi
}

log()
{
	pattern="*.build"
	if [ -n $1 ]; then
		pattern="*${1}*.build"
	fi
	pager `ls -t $pattern ../$pattern | head -n1`
}

tag()
{
	git-buildpackage --git-ignore-new --git-tag-only
}

commit()
{
	VERSION=`dpkg-parsechangelog | awk '/^Version: / {print $2}'`
	git add debian/changelog && git commit -m "debian/changelog: $VERSION"
}

push()
{
	git push
	git push --tags
}

repo()
{
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

watch()
{
	if [ x"$1" = x"" ]; then
		src_dir=`pwd`
	else
		src_dir=$1
	fi
	for source in $src_dir/*
	do
		debian_dist=squeeze
		if [ -f $source/watch ]; then
			debian_changelog=`ls $source/*/debian/changelog|head -n1`
			debian_source=`dpkg-parsechangelog -l$debian_changelog | awk '/^Source: / {print $2}'`
			debian_version=`dpkg-parsechangelog -l$debian_changelog | awk '/^Version: / {print $2}'`
			parse_dist=`dpkg-parsechangelog -l$debian_changelog | awk '/^Distribution: / {print $2}'`
			case $parse_dist in
				*-backports)
					debian_dist=$parse_dist
				;;
				*)
				;;
			esac
			. $source/watch
			upstream_version=`curl -s http://packages.debian.org/source/${debian_dist}/${debian_source} | grep "Source Package: ${debian_source}" | awk -F'(\(|\))' '{print $2}'`
			if [ x"$upstream_version" != x"" ]; then
				#echo "${debian_source}: ${debian_dist} u(${upstream_version}) l(${debian_version})"
				if dpkg --compare-versions "$upstream_version" gt "$debian_version"; then
					echo "${debian_source}: new debian version ${upstream_version} > ${debian_version}"
				fi
			else
				echo "${debian_source}: can't get upstream version"
			fi
		fi
	done
}

action=$1

case "$action" in
	create | update)
		jobidx=1
		pidlist=""
		log_dir=`mktemp -d`
		echo "+++ starting $action, see $log_dir for logs +++"
		for i in $DISTS
		do
			for j in $ARCHS
			do
				echo "[$jobidx] $action for $i $j"
				sudo DIST=$i ARCH=$j pbuilder $action --othermirror "deb http://repo.163.org/debian ${i} main contrib non-free" >& $log_dir/${i}_${j}_${action}.log &
				pidlist="$pidlist $!"
				let "jobidx+=1"
			done
		done

		jobidx=1
		failed=0
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
			echo "$failed $action(s) failed, please check $action log in $log_dir"
		else
			echo "$action all done, cleaning log"
			rm -r $log_dir
		fi
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
			echo "    post-build"
			echo "    repo"
			echo "    log [pattern]"
			echo "    commit"
			echo "    push"
			echo "    tag"
			exit 1
		fi
		;;
esac
