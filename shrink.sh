#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

inputfile="$1"
gpinitconfig="$2"
parallel="$3"

if [[ "$inputfile" == "" || "$gpinitconfig" == "" || "$parallel" == "" ]]; then
	echo "Please provide the input file name, the old database initialization file, and how much parallelism."
	echo "Example:"
	echo "./shrink.sh gpexpand_inputfile_20161012_174056 gp_init_config 10"
	exit 1
fi
if [ ! -f "$inputfile" ]; then
	echo "input file not found: $inputfile"
	exit 1
fi
if [ ! -f "$gpinitconfig" ]; then
	echo "gp_init_config not found: $gpinitconfig"
	exit 1
fi
if [ "$MASTER_DATA_DIRECTORY" == "" ]; then
	echo "MASTER_DATA_DIRECTORY is not set!"
	exit 1
fi
if [ "$PGDATABASE" == "" ]; then
	PGDATABASE="gpadmin"
fi

masterdirbackup="$MASTER_DATA_DIRECTORY""_backup"

read -r -p "Is this a new shrink?  (Yes or No)" response
case $response in
	[yY][eE][sS]|[yY])
		echo "Removing any logs from previous shrink."
		echo "rm -f $PWD/log/end_shrink_*"
		rm -f $PWD/log/end_shrink_*
		;;
	*)
		echo "Continue..."
	;;
esac

checkgpinitconfig()
{

	echo "Checking $gpinitconfig"
	count=$(grep "#DATABASE_NAME" $gpinitconfig | wc -l)
	if [ "$count" -gt 0 ]; then
		echo "DATABASE_NAME must be set in your initialization file!"
		exit 1
	fi

	count=$(grep "^MIRROR*" $gpinitconfig | wc -l)
	if [ "$count" -gt 0 ]; then
		echo "MIRROR* needs to be removed or commented out from your initialization file!"
		exit 1
	fi

	count=$(grep "^declare -a MIRROR_DATA_DIRECTORY*" $gpinitconfig | wc -l)
	if [ "$count" -gt 0 ]; then
		echo "MIRROR_DATA_DIRECTORY needs to be removed or commented out from your initialization file!"
		exit 1
	fi
	echo "Config OK $gpinitconfig"
}
checkbackup()
{
	if [ -d $MASTER_DATA_DIRECTORY/db_dumps/ ]; then
		echo "The latest backup will be used to shrink the database.  Here are the backup directories:"
		for i in $(ls $MASTER_DATA_DIRECTORY/db_dumps/); do
			echo $i
		done
	else
		echo "No backups found!  Can not shrink database!"
		exit 1
	fi
}
stopdb()
{
	counter=$(ps -ef | grep postgres | grep "\-D" | wc -l)

	if [ "$counter" -gt "0" ]; then
		gpstop -a -M fast
	else
		echo "Database already stopped."
	fi
}
rename_expanded_dir()
{
	# rename the expanded directories to _backup
	end="$PWD""/log/end_shrink_rename.log"
	if [ ! -f "$end" ]; then
		stopdb
		echo "mv $MASTER_DATA_DIRECTORY $masterdirbackup"
		mv $MASTER_DATA_DIRECTORY $masterdirbackup

		for i in $(cat $inputfile | awk -F ':' '{print $2 "|" $4}' | awk -F 'gpseg' '{print $1}' | sort | uniq); do
			exthost=$(echo $i | awk -F '|' '{print $1}')
			extpath=$(echo $i | awk -F '|' '{print $2}')
			ssh $exthost "bash -c 'for x in \$(ls $extpath); do echo \"mv $extpath\$x $extpath\$x\"_backup\"\"; mv $extpath\$x $extpath\$x\"_backup\"; done'"
		done
		touch "$end"
	fi
}
init_db()
{
	end="$PWD""/log/end_shrink_init.log"
	if [ ! -f "$end" ]; then
		stopdb
		echo "init the new database"
		#gpinitsystem returns 1 even when it completes successfully because of email alert.
		gpinitsystem -c $gpinitconfig -a || true
		echo "host all all 0.0.0.0/0 md5" >> $MASTER_DATA_DIRECTORY/pg_hba.conf
		gpstop -u
		psql -c "alter user gpadmin password 'changeme'"
		touch "$end"
	else
		echo "database already initialized"
	fi
}
move_backup()
{
	end="$PWD""/log/end_shrink_move.log"
	if [ ! -f "$end" ]; then
		# move the backup directories back for the restore
		for i in $(psql -t -A -c "SELECT hostname, fselocation || '/', fselocation || '_backup/db_dumps/' FROM gp_segment_configuration JOIN pg_filespace_entry ON (dbid = fsedbid) JOIN pg_filespace fs ON (fs.oid = fsefsoid) WHERE fsname = 'pg_system' and content >= 0;"); do 
			exthost=$(echo $i | awk -F '|' '{print $1}')
			extpath=$(echo $i | awk -F '|' '{print $2}')
			backuppath=$(echo $i | awk -F '|' '{print $3}')
			ssh $exthost "bash -c 'echo \"mv $backuppath $extpath\"; mv $backuppath $extpath'"
		done

		echo "mv $masterdirbackup"/db_dumps/" $MASTER_DATA_DIRECTORY"
		mv $masterdirbackup"/db_dumps/" $MASTER_DATA_DIRECTORY

		checkbackup
		touch "$end"
	fi
}
restore_db()
{
	end="$PWD""/log/end_shrink_restore.log"
	if [ ! -f "$end" ]; then
		echo "gpdbrestore -a -G include -e -s $PGDATABASE --noanalyze"
		gpdbrestore -a -G include -e -s $PGDATABASE --noanalyze || true
		touch "$end"
	fi
}
analyze_db()
{
	end="$PWD""/log/end_shrink_analyze.log"
	if [ ! -f "$end" ]; then
		echo "analyzedb -d $PGDATABASE -a -p $parallel"
		analyzedb -d $PGDATABASE -a -p $parallel
		touch "$end"
	fi
}
vacuum_db()
{
	end="$PWD""/log/end_shrink_vacuum.log"
	if [ ! -f "$end" ]; then
		echo "psql -c \"vacuum full\""
		psql -c "vacuum full"
		touch "$end"
	fi
}
cleanup()
{
	end="$PWD""/log/end_shrink_cleanup.log"
	if [ ! -f "$end" ]; then
		echo "rm -rf $masterdirbackup"
		rm -rf $masterdirbackup

		for i in $(psql -t -A -c "SELECT distinct hostname, array_to_string(((string_to_array(fselocation, '/'))[1:(array_upper(string_to_array(fselocation, '/'), 1)-1)]), '/') || '/*_backup' FROM gp_segment_configuration JOIN pg_filespace_entry ON (dbid = fsedbid) JOIN pg_filespace fs ON (fs.oid = fsefsoid) WHERE fsname = 'pg_system' and content >= 0;"); do
			exthost=$(echo $i | awk -F '|' '{print $1}')
			extpath=$(echo $i | awk -F '|' '{print $2}')
			echo "ssh $exthost \"bash -c 'rm -rf $extpath'\""
			ssh $exthost "bash -c 'rm -rf $extpath'"
		done
		touch "$end"
	fi

}

checkgpinitconfig
rename_expanded_dir
init_db
move_backup
restore_db
analyze_db
vacuum_db
cleanup
echo "Shrink complete!"
