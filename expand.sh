#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

parallel=$1

if [[ "$parallel" == "" ]]; then
	echo "Please provide how much parallelism."
	echo "Example:"
	echo "./expand.sh 10"
	exit 1
fi

if [ "$MASTER_DATA_DIRECTORY" == "" ]; then
	echo "MASTER_DATA_DIRECTORY is not set!"
	exit 1
fi

if [ "$PGDATABASE" == "" ]; then
	PGDATABASE="gpadmin"
fi

read -r -p "Is this a new expansion?  (Yes or No)" response
case $response in
	[yY][eE][sS]|[yY])
		echo "Removing any logs from previous expansion."
		echo "rm -f $PWD/log/end_expand_*"
		rm -f $PWD/log/end_expand_*
		echo "rm -f $PWD/gpexpand_inputfile*"
		rm -f $PWD/gpexpand_inputfile*
		;;
	*)
		echo "Continue..."
	;;
esac

backupdb()
{
	end="$PWD""/log/end_expand_backup.log"
	if [ ! -f "$end" ]; then
		gpcrondump -x $PGDATABASE -a -c -g -G -C
		touch "$end"
	else
		echo "Database already backed up."
	fi
}
checkbackup()
{
	if [ -d $MASTER_DATA_DIRECTORY/db_dumps/ ]; then
		echo "The latest backup will be used if you wish to shrink the database.  Here are the backup directories:"
		for i in $(ls $MASTER_DATA_DIRECTORY/db_dumps/); do
			echo $i
		done
	else
		echo "No backups found!"
		read -r -p "Do you want to execute a backup now? (Yes or No)" response
		case $response in
			[yY][eE][sS]|[yY])
				echo "Executing backup..."
				backupdb
				;;
			*)
				echo "Can not continue without a valid backup."
				exit 1
			;;
		esac
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
startdb()
{
	counter=$(ps -ef | grep postgres | grep "\-D" | wc -l)

	if [ "$counter" -eq "0" ]; then
		gpstart -a
	else
		echo "Database already started."
	fi
}
createifile()
{
	gpexpand -D $PGDATABASE
}
getifilename()
{
	ifile=""
	count=$(ls $PWD/gpexpand_inputfile_* 2> /dev/null | wc -l)
	if [ "$count" -eq "1" ]; then
		ifile=$(ls $PWD/gpexpand_inputfile_*)
	fi
}
expandcluster()
{
	end="$PWD""/log/end_expand_cluster.log"
	if [ ! -f "$end" ]; then
		cat $ifile
		echo ""
		read -r -p "Does the expansion file look correct? (Yes or No)" response
		case $response in
			[yY][eE][sS]|[yY])
				echo "Continue..."
				;;
			*)
				rm -f $ifile	
				exit 1
			;;
		esac
		#this expands the cluster
		echo "gpexpand -i $ifile -D $PGDATABASE"
		gpexpand -i $ifile -D $PGDATABASE
		touch "$end"
	else
		echo "Database already expanded."
	fi
}
redistribute()
{
	end="$PWD""/log/end_expand_redistribute.log"
	if [ ! -f "$end" ]; then
		#redistribute the data with n parallel processes
		echo "gpexpand -D $PGDATABASE -n $parallel"
		gpexpand -D $PGDATABASE -n $parallel
		touch "$end"
	else
		echo "Database already redistributed."
	fi
}
analyze()
{
	end="$PWD""/log/end_expand_analyze.log"
	if [ ! -f "$end" ]; then
		#analyze the database
		echo "analyzedb -d $PGDATABASE -a -p $parallel"
		analyzedb -d $PGDATABASE -a -p $parallel
		touch "$end"
	else
		echo "Database already analyzed."
	fi
}

startdb
checkbackup
getifilename
if [ "$ifile" == "" ]; then
	createifile
fi
getifilename
if [ "$ifile" == "" ]; then
	echo "Expand file not created!"
	exit 1
else
	echo "ifile: $ifile"
fi

expandcluster
redistribute
analyze
echo "Expansion complete!"
