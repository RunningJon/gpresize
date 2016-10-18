#!/bin/bash
set -e

PWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

standby_master="$1"

echo "Standby Master: $standby_master"
read -p "Hit enter to continue or control+c to exit..."

mirrors_init_config="$PWD""/mirrors_init_config"

check_for_mirrors()
{
	mirrors_count=$(psql -t -A -c "select count(*) from gp_segment_configuration where content >= 0 and role = 'm'")
}
create_mirrors_init_config()
{
	gpaddmirrors -o mirrors_init_config
}
check_mirrors_init_config()
{
	if [ ! -f "$mirrors_init_config" ]; then
		echo "mirrors_init_config not found!"
		exit 1
	fi
}
remove_mirror_directories()
{
	for i in $(grep mirror mirrors_init_config | awk -F ':' '{print $2 "|" $6}'); do
		ext_host=$(echo $i | awk -F '|' '{print $1}')
		ext_dir=$(echo $i | awk -F '|' '{print $2}')
		echo "ssh $ext_host \"bash -c 'rm -rf $ext_dir'\""
		ssh $ext_host "bash -c 'rm -rf $ext_dir'"
	done
}
add_mirrors()
{
	gpaddmirrors -a -i mirrors_init_config
}
check_status()
{
	mirror_status=$(psql -t -A -c "select count(*) from gp_segment_configuration where mode = 'r'")
}
add_standby()
{
	if [ "$standby_master" != "" ]; then
		masters_count=$(psql -t -A -c "select count(*) from gp_segment_configuration where content = -1;")
		if [ "$masters_count" -eq "1" ]; then
			echo "ssh $standby_master \"bash -c 'rm -rf $MASTER_DATA_DIRECTORY'\""
			ssh $standby_master "bash -c 'rm -rf $MASTER_DATA_DIRECTORY'"
			echo "gpinitstandby -s $standby_master"
			gpinitstandby -s $standby_master
		fi
	fi
}

check_for_mirrors

if [ "$mirrors_count" -eq "0" ]; then
	create_mirrors_init_config
	check_mirrors_init_config
	remove_mirror_directories
	add_mirrors
fi

check_status
echo -ne "Adding mirrors."
while [ "$mirror_status" -gt "0" ]; do
	echo -ne "."
	sleep 10
	check_status
done
echo ""
add_standby
echo "Done!"
