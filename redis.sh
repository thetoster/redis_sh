#!/bin/bash
#
# Copyright (c) 2020, celadari (https://github.com/celadari/redis_sh)
#
# Permission to use, copy, modify, and/or distribute this software
# for any purpose with or without fee is hereby granted, provided
# that the above copyright notice and this permission notice appear
# in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
# WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
# AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
# CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
# OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
# NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
# CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# This file incorporates work covered by the following copyright and
# permission notice:
#
#     Copyright (c) 2015,  crypt1d
#
#     Permission to use, copy, modify, and/or distribute this software
#     for any purpose with or without fee is hereby granted, provided
#     that the above copyright notice and this permission notice appear
#     in all copies.
#
#     THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
#     WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
#     WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
#     AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
#     CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
#     OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
#     NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
#     CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_DB="${REDIS_DB:-0}"
REDIS_ARRAY_RANGE="0,-1"
REDIS_WIPEOUT=""

function redis_read_str() {
        typeset REDIS_STR="$@"
        printf %b "$REDIS_STR" | cut -f2- -d+ | tr -d '\r'
}

function redis_read_err() {
        typeset REDIS_ERR="$@"
        printf %s "$REDIS_ERR" | cut -f2- -d-
        exit 1
}

function redis_read_int() {
        typeset -i OUT_INT=$(printf %s "$1" | tr -d : | tr -d '\r')
        printf %b "$OUT_INT"
}

function redis_read_bulk() {
        typeset -i BYTE_COUNT=$1
        typeset -i FILE_DESC=$2
        if [[ $BYTE_COUNT -lt 0 ]]; then
                echo ERROR: Null or incorrect string size returned. >&2
		            exec {FILE_DESC}>&-
                exit 1
        fi

        echo $(dd bs=1 count=$BYTE_COUNT status=noxfer <&$FILE_DESC 2>/dev/null)
        dd bs=1 count=2 status=noxfer <&$FILE_DESC 1>/dev/null 2>&1 # we are removing the extra character \r
}

function redis_read() {

        typeset -i FILE_DESC=$1

        if [[ $# -eq  2 ]]; then
          typeset -i PARAM_COUNT=$2
          typeset -i PARAM_CUR=1
        fi

        while read -r socket_data
        do
                typeset first_char
                first_char=$(printf %b "$socket_data" | head -c1)

                case $first_char in
                        '+')
                                redis_read_str "$socket_data"
                                ;;
                        '-')
                                redis_read_err "$socket_data"
                                ;;
                        ':')
                                redis_read_int "$socket_data"
                                ;;
                        '$')
                                bytecount=$(printf %b "$socket_data" | cut -f2 -d$ | tr -d '\r')
                                redis_read_bulk "$bytecount" "$FILE_DESC"
                                ;;
                        '*')
                                paramcount=$(printf %b "$socket_data" | cut -f2 -d* | tr -d '\r')
                                redis_read "$FILE_DESC" "$paramcount"
                                ;;
                esac

                if [[ ! -z $PARAM_COUNT ]]; then
                      if [[ $PARAM_CUR -lt $PARAM_COUNT ]]; then
                          ((PARAM_CUR+=1))
                          continue
                      else
                              break
                      fi
                else
                      break
                fi

        done<&"$FILE_DESC"

}

function redis_compose_cmd() {
        typeset REDIS_PASS="$1"
        printf %b "*2\r\n\$4\r\nAUTH\r\n\$${#REDIS_PASS}\r\n$REDIS_PASS\r\n"
}

function redis_select_db() {
        typeset REDIS_DB="$1"
        printf %b "*2\r\n\$6\r\nSELECT\r\n\$${#REDIS_DB}\r\n$REDIS_DB\r\n"
}


function redis_get_var() {
        typeset REDIS_KEY="$1"
        printf %b "*2\r\n\$3\r\nGET\r\n\$${#REDIS_KEY}\r\n$REDIS_KEY\r\n"
}

function redis_set_var() {
        typeset REDIS_VAR="$1"
        shift
        typeset REDIS_VAR_VAL="$@"
        printf %b "*3\r\n\$3\r\nSET\r\n\$${#REDIS_VAR}\r\n$REDIS_VAR\r\n\$${#REDIS_VAR_VAL}\r\n$REDIS_VAR_VAL\r\n"
}

function redis_get_array() {
        typeset REDIS_KEY="$1"
        RANGE_LOW=$(echo $2 | cut -f1 -d,)
        RANGE_HIGH=$(echo $2 | cut -f2 -d,)
        printf %b "*4\r\n\$6\r\nLRANGE\r\n\$${#REDIS_KEY}\r\n$REDIS_KEY\r\n\$${#RANGE_LOW}\r\n$RANGE_LOW\r\n\$${#RANGE_HIGH}\r\n$RANGE_HIGH\r\n"
}

function redis_get_hash() {
        typeset redis_key="$1"
        typeset redis_field="$2"
        if [[ -z $redis_field ]] ; then
          printf %b "*2\r\n\$5\r\nHVALS\r\n\$${#redis_key}\r\n$redis_key\r\n"
        else
          printf %b "*3\r\n\$4\r\nHGET\r\n\$${#redis_key}\r\n$redis_key\r\n\$${#redis_field}\r\n$redis_field\r\n"
        fi
}

function redis_set_array() {
        typeset REDIS_ARRAY="$1"
        typeset -a REDIS_ARRAY_VAL=("${!2}")

        printf %b "*2\r\n\$3\r\nDEL\r\n\$${#REDIS_ARRAY}\r\n$REDIS_ARRAY\r\n"
        for i in "${REDIS_ARRAY_VAL[@]}"
        do
          printf %b "*3\r\n\$5\r\nRPUSH\r\n\$${#REDIS_ARRAY}\r\n$REDIS_ARRAY\r\n\$${#i}\r\n$i\r\n"
        done
}

function redis_set_hash() {
        typeset redis_key="$1"
        typeset redis_field="$2"
        typeset redis_value="$3"

        printf %b "*4\r\n\$4\r\nHSET\r\n\$${#redis_key}\r\n$redis_key\r\n\$${#redis_field}\r\n$redis_field\r\n\$${#redis_value}\r\n$redis_value\r\n"
}

function redis_wipeout_all() {
  printf %b "*1\r\n\$7\r\nFLUSHDB\r\n"
}

function redis_wipeout() {
  typeset redis_key="$1"
  printf %b "*2\r\n\$3\r\DEL\r\n\$${#redis_key}\r\n$redis_key\r\n"
}

while getopts g:s:r:P:H:p:d:f:ha:w:W opt; do
	case $opt in
		p)
			REDIS_PW=${OPTARG}
			;;
		H)
			REDIS_HOST=${OPTARG}
			;;
		P)
			REDIS_PORT=${OPTARG}
			;;
		g)
			REDIS_GET=${OPTARG}
			;;
	  h)
	    REDIS_HASH=1
	    ;;
	  f)
	    REDIS_FIELD=${OPTARG}
	    ;;
		a)
			REDIS_ARRAY=1
			;;
		r)
			REDIS_ARRAY_RANGE=${OPTARG}
			;;
		s)
			REDIS_SET=${OPTARG}
			;;
    d)
			REDIS_DB=${OPTARG}
			;;
	  w)
	    REDIS_WIPEOUT=${OPTARG}
	    ;;
	  W)
	    REDIS_WIPEOUT="*"
	    ;;
		*)
			echo
			echo USAGE:
			echo "	$0 [-a|-h] [-W] [-w <var>] [-r <range>] [-s <var>] [-g <var>] [-f <field>] [-p <password>] [-d <database_number>] [-H <hostname>] [-P <port>]"
			echo
			exit 1
			;;
	esac
done

if [[ -z $REDIS_GET ]] && [[ -z $REDIS_SET ]] && [[ -z $REDIS_WIPEOUT ]]; then
	echo "You must either GET(-g) or SET(-s) or WIPEOUT(-W, -w)" >&2
	exit 1
fi

if [[ $REDIS_ARRAY -eq 1 ]] && [[ $REDIS_HASH -eq 1 ]]; then
	echo "You must not use '-a' (array) and '-h' (hash) at the same time" >&2
	exit 1
fi

exec {FD}<> /dev/tcp/"$REDIS_HOST"/"$REDIS_PORT"

redis_select_db "$REDIS_DB" >&$FD
redis_read $FD 1>/dev/null 2>&1

if [[ ! -z $REDIS_PW ]]; then
	redis_compose_cmd "$REDIS_PW" >&$FD
    redis_read $FD 1>/dev/null 2>&1
fi

if [[ ! -z $REDIS_WIPEOUT ]]; then
  if [[ "*" == $REDIS_WIPEOUT ]] ; then
    redis_wipeout_all >&$FD
  else
    redis_wipeout "$REDIS_WIPEOUT" >&$FD
  fi

  exec {FD}>&-
  exit 0
fi

if [[ ! -z $REDIS_GET ]]; then
	if [[ $REDIS_ARRAY -eq 1 ]] || [[ $REDIS_HASH -eq 1 ]] ; then
	  if [[ $REDIS_ARRAY -eq 1 ]] ; then
		  redis_get_array "$REDIS_GET" "$REDIS_ARRAY_RANGE" >&$FD
		else
		  redis_get_hash "$REDIS_GET" "$REDIS_FIELD" >&$FD
		fi
		IFS=$'\n'

		for i in $(redis_read $FD)
		do
			echo $i
		done
	else
		redis_get_var "$REDIS_GET" >&$FD
		redis_read $FD
	fi

	exec {FD}>&-
	exit 0
fi

while read -r line
do
        REDIS_TODO=$line
done </dev/stdin

if [[ -n $REDIS_SET ]]; then
	if [[ $REDIS_ARRAY -eq 1 ]] || [[ $REDIS_HASH -eq 1 ]] ; then
	  if [[ $REDIS_ARRAY -eq 1 ]] ; then
		  set -- $REDIS_TODO
		  typeset -a temparray=( $@ )
		  redis_set_array "$REDIS_SET" temparray[@] >&$FD
		else
		  redis_set_hash "$REDIS_SET" "$REDIS_FIELD" "$REDIS_TODO" >&$FD
		fi
		redis_read $FD 1>/dev/null 2>&1
	else
		redis_set_var "$REDIS_SET" "$REDIS_TODO" >&$FD
		redis_read $FD 1>/dev/null 2>&1
	fi
	exec {FD}>&-
	exit 0
fi