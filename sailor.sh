#!/bin/sh

usage()
{
	echo "usage: $0 build <ship.conf>"
	echo "       $0 start <ship.conf>"
	echo "       $0 stop <ship id>"
	echo "       $0 status <ship id>"
	echo "       $0 destroy <ship.conf>"
	echo "       $0 ls"
	exit 1
}

[ $# -lt 1 ] && usage

cmd=${1}
param=${2}

. ./platform.sh
. ./deps.sh

if [ -f "${param}" ]; then
	param="`dirname ${param}`/`basename ${param}`"
	. ${param}
fi

reqs=""
libs=""
varbase=`${pkg_info} -QVARBASE pkgin`
varrun="${varbase}/run/sailor"

[ ! -d "${varrun}" ] && ${mkdir} ${varrun}

has_services()
{
	[ -z "${services}" ] && return 1 || return 0
}

build()
{
	[ ! -d ${shippath} ] && ${mkdir} ${shippath} || exit 1

	# install wanted binaries
	prefix=`${pkg_info} -QLOCALBASE pkgin`
	sysconfdir=`${pkg_info} -QPKG_SYSCONFDIR pkgin`

	for bin in ${def_bins} ${shipbins}
	do
		bin_requires ${bin}
	done

	# devices
	${mkdir} ${shippath}/dev
	mkdevs
	
	# tmp directory
	${mkdir} ${shippath}/tmp
	chmod 1777 ${shippath}/tmp
	
	# needed for pkg_install / pkgin to work
	for d in db/pkg db/pkgin log run tmp
	do
		${mkdir} ${shippath}/${varbase}/${d}
	done
	
	${rsync} ${prefix}/etc/pkgin ${shippath}/${sysconfdir}/
	
	# raw pkg_install / pkgin installation
	pkg_requires pkg_install
	for p in pkg_install pkgin
	do
		${pkg_tarup} -d ${shippath}/tmp ${p}
		${tar} zxfp ${shippath}/tmp/${p}*tgz -C ${shippath}/${prefix}
	done
	bin_requires ${prefix}/sbin/pkg_add
	bin_requires ${prefix}/bin/pkgin
	# install pkg{_install,in} the right way
	chroot ${shippath} ${prefix}/sbin/pkg_add /tmp/pkg_install*
	
	# minimal etc provisioning
	${mkdir} ${shippath}/etc
	${cp} /usr/share/zoneinfo/GMT ${shippath}/etc/localtime
	${cp} /etc/resolv.conf ${shippath}/etc/
	# custom /etc
	common="ships/common/${OS}"
	# populate commons
	[ -d ${common} ] && ${rsync} ${common}/ ${shippath}/
	# populate 3rd party
	[ -d ships/${shipname} ] && ${rsync} ships/${shipname}/ ${shippath}/
	# fix etc perms
	${chown} -R root:wheel ${shippath}/etc
	master_passwd=${shippath}/etc/master.passwd
	[ -f ${master_passwd} ] && ${chmod} 600 ${master_passwd}
	
	need_tools pkgin
	
	${pkgin} -y -c ${shippath} update
	
	for pkg in ${packages}
	do
		# retrieve dependencies names
		pkg_reqs="`${pkgin} -P -c ${shippath} sfd ${pkg} | \
			awk '/^\t/ {print $1}'` ${pkg}"
		for p in ${pkg_reqs}
		do
			# install all dependencies requirements
			pkg_requires ${p}
		done
	done
	PKG_RCD_SCRIPTS=yes ${pkgin} -y -c ${shippath} install ${packages}
	${pkgin} -y clean

	has_services && for s in ${services}
	do
		echo "${s}=YES" >> ${shippath}/etc/rc.conf
	done
	shipid=`${od} -A n -t x -N 8 /dev/urandom|${tr} -d ' '`
	echo ${shipid} > ${shippath}/shipid
}

has_shipid()
{
	[ -f ${shippath}/shipid ] && return 0 || return 1
}

get_shipid()
{
	has_shipid && ${cat} ${shippath}/shipid
}

case ${cmd} in
build|create|make)
	if [ -z "${shippath}" -o "${shippath}" = "/" ]; then
		echo "ABORTING: \"\$shippath\" set to \"$shippath\""
		exit 1
	fi
	if has_shipid; then
		echo "ship already exists with id `get_shipid`"
		exit 1
	fi

	build
	;;
destroy)
	if ! has_shipid; then
		echo "ship does not exist"
		exit 1
	fi
	shipid=`get_shipid`
	if [ -f ${varrun}/${shipid}.ship ]; then
		echo "ship is running with id ${shipid}, not destroying"
		exit 1
	fi
	printf "really delete ship ${shippath}? [y/N] "
	read reply
	case ${reply} in
	y|yes)
		${rm} -rf ${shippath}
		;;
	*)
		exit 0
		;;
	esac
	;;
start|stop|status)
	# parameter is a ship id
	if [ ! -f ${param} ]; then
		shipid=${varrun}/${param}.ship
		if [ ! -f ${shipid} ]; then
			echo "invalid ship id \"${param}\""
			exit 1
		fi
		. ${shipid}
	fi

	has_services && for s in ${services}
	do
		chroot ${shippath} /etc/rc.d/${s} ${cmd}
	done
	case ${cmd} in
	start)
		mounts mount

		shipid=`${cat} ${shippath}/shipid`
		varfile=${varrun}/${shipid}.ship
		echo "id=${shipid}" > ${varfile}
		echo "cf=${param}" >> ${varfile}
		${cat} ${param} >> ${varfile}
		;;
	stop)
		mounts umount
		${rm} ${varrun}/${param}.ship
		;;
	esac
	;;
ls)
	for f in ${varrun}/*.ship
	do
		[ ! -f "${f}" ] && exit 0
		. ${f}
		. ${cf}
		echo "${id} - ${shipname} - ${cf}"
	done
	;;
*)
	usage
	;;
esac

exit 0
