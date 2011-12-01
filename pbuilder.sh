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

build_all()
{
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
			if [ x"$action" = x"gbp" ]; then
				DIST=$i ARCH=$j git-buildpackage --git-submodules --git-ignore-new --git-builder="pdebuild $inc_orig $build_bin_only" --git-cleaner='/bin/true' >&/dev/null &
				pidlist="$pidlist $!"
			else
				DIST=$i ARCH=$j pdebuild $inc_orig $build_bin_only >&/dev/null &
				pidlist="$pidlist $!"
			fi
			inc_orig=""
			build_bin_only="-- --binary-arch"
			let "jobidx+=1"
			#sleep 5
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
	repo
	echo "+++ git taging +++"
	git-buildpackage --git-ignore-new --git-tag-only
	echo "+++ git clean up +++"
	git reset --hard HEAD && git clean -df
}

log()
{
	pattern="*.build"
	if [ -n $1 ]; then
		pattern="*${1}*.build"
	fi
	pager `ls -t $pattern ../$pattern | head -n1`
}

commit()
{
	git add debian/changelog && git commit -m "debian/changelog: $(dpkg-parsechangelog | awk '/^Version: / {print $2}')"
}

repo()
{
	echo "+++ installing build results +++"
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
		jobidx=1
		pidlist=""
		log_dir=`mktemp -d`
		echo "+++ starting $action, see $log_dir for logs +++"
		for i in $DISTS
		do
			for j in $ARCHS
			do
				echo "[$jobidx] $action for $i $j"
				sudo DIST=$i ARCH=$j pbuilder $action >& $log_dir/${i}_${j}_${action}.log &
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
			echo "    repo"
			echo "    log [pattern]"
			echo "    commit"
			exit 1
		fi
		;;
esac
