#!/bin/bash
set -e
gpstop -a
gpstart -m
PGOPTIONS='-c gp_session_role=utility' psql -c "SET allow_system_table_mods=dml; update gp_fault_strategy set fault_strategy = 'n';"
PGOPTIONS='-c gp_session_role=utility' psql -c "SET allow_system_table_mods=dml; delete from gp_segment_configuration where role = 'm';"
PGOPTIONS='-c gp_session_role=utility' psql -c "SET allow_system_table_mods=dml; update gp_segment_configuration set replication_port = null;"
#PGOPTIONS='-c gp_session_role=utility' psql -c "SET allow_system_table_mods=dml; delete from pg_filespace_entry where fselocation like '%mirror%';"
PGOPTIONS='-c gp_session_role=utility' psql -c "SET allow_system_table_mods=dml; delete from pg_filespace_entry f where not exists (select null from gp_segment_configuration g where f.fsedbid = g.dbid);"
gpstop -m
gpstart -a

