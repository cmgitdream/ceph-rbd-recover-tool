#!/bin/bash
# author: min chen(minchen@ubuntukylin.com) 2014

# unit test case for image with nosnap

#step 1. rbd export all images as you need
#step 2. stop all ceph services
#step 3. use rbd_recover_tool to recover all images
#step 4. compare md5sum of recover image with that of export image who has the same image name

ssh_opt="-o ConnectTimeout=1"
my_dir=$(dirname "$0")
tool_dir=$my_dir

storage_path=$my_dir/storage_path
mon_host=$my_dir/mon_host
osd_host=$my_dir/osd_host
mds_host=$my_dir/mds_host

test_dir=
export_dir=
recover_dir=
image_names=
online_images= #all images on ceph rbd pool
gen_db= #label database if exist

function init()
{
  local func="init"
  if [ ! -s $storage_path ];then
    echo "$func: storage_path not input, make sure the disk enough space"
    exit
  fi    
  if [ ! -s $mon_host ];then
    echo "$func: mon_host not exists or empty"
    exit
  fi
  if [ ! -e $mds_host ];then
    echo "$func: mds_host not exists"
    exit
  fi
  test_dir=`cat $storage_path`
  export_dir=$test_dir/export
  recover_dir=$test_dir/recover
  image_names=$test_dir/image_names
  online_images=$test_dir/online_images
  gen_db=$test_dir/gen_db
  
  mkdir -p $test_dir
  mkdir -p $export_dir
  mkdir -p $recover_dir
}

function get_all_images_online()
{
  rados lspools|xargs -n 1 -I @ rbd ls @ >$online_images   
}

function clear_image_names()
{
  >$image_names
}

function read_image_names()
{
  local func="read_images_names"
  count=0;
  cat |
  while read name
  do
    count=$(($count + 1))
    if [ "`grep "^$name$" $online_images`"x = ""x ];then
      echo "$func: $name not in online_images"    
      continue
    fi
    if [ $count = 10 ];then
      echo;
    fi
    echo -n "$name "
    echo $name >>$image_names
  done 
  echo
}

function export_images()
{
  local func="export_images"
  while read image
  do
    rm $export_dir/$image
    rbd export $image $export_dir/$image
  done < $image_names  
}

function do_gen_database()
{
  local func="do_gen_database"
  if [ -s $gen_db ] && [ `cat $gen_db` = 1 ];then
    echo "$func: database already existed"
    exit
  fi
  bash $tool_dir/admin_job database
  echo 1 >$gen_db 
}

function recover_images()
{
  local func="recover_images"
  echo "$func: cat image_names ..."
  cat $image_names;
  cat $image_names|xargs -n 1 -I @ bash $tool_dir/admin_job recover @ $recover_dir
}

function check_md5sum()
{
  local func="check_md5sum"
  cat |
  while read image
  do
    export_img=$export_dir/$image
    recover_img=$recover_dir/$image
    export_md5=`md5sum $export_img|awk '{print $1}'` 
    recover_md5=`md5sum $recover_img|awk '{print $1}'` 
    ifpassed="PASSED"
    ifequal="=="
    if [ $recover_md5 != $export_md5 ];then
      ifpassed="FAILED"
      ifequal="!=" 
    fi
    echo -e "$image:\t$ifpassed\n\t\t$recover_md5 [$recover_img] \n\t\t$export_md5 [$export_img]"
  done 
}

#check if stop all ceph processes
function check_ceph_service()
{
  local func="check_ceph_service"
  local res=`cat $osd_host $mon_host $mds_host|sort -u|tr -d [:blank:]|xargs -n 1 -I @ ssh $ssh_opt @ "ps aux|grep -E \"(ceph-osd|ceph-mon|ceph-mds)\"|grep -v grep"`
  if [ "$res"x != ""x ];then
    echo "$func: NOT all ceph services are stopped"
    exit
  fi
  echo "$func: all ceph services are stopped"
}

function stop_ceph()
{
  local func="stop_ceph"
  #cat osd_host|xargs -n 1 -I @ ssh $ssh_opt @ "killall ceph-osd" 
  while read osd
  do
  {
    osd=`echo $osd|tr -d [:blank:]`
    if [ "$osd"x = ""x ];then
      continue
    fi
    #ssh $ssh_opt $osd "killall ceph-osd ceph-mon ceph-mds" </dev/null
    ssh $ssh_opt $osd "killall ceph-osd" </dev/null
  } &
  done < $osd_host
  wait
  echo "waiting kill all osd ..."
  sleep 1
  #cat $mon_host|xargs -n 1 -I @ ssh $ssh_opt @ "killall ceph-mon ceph-osd ceph-mds" 
  cat $mon_host|xargs -n 1 -I @ ssh $ssh_opt @ "killall ceph-mon" 
  #cat $mds_host|xargs -n 1 -I @ ssh $ssh_opt @ "killall ceph-mds ceph-mon ceph-osd" 
  cat $mds_host|xargs -n 1 -I @ ssh $ssh_opt @ "killall ceph-mds" 
}

function create_image()
{
  local func="create_image"
  if [ ${#} -lt 3 ];then
    echo "create_image: parameters: <image_name> <size> <image_format>"
    exit
  fi
  local image_name=$1
  local size=$2
  local image_format=$3
  if [ $image_format -lt 1 ] || [ $image_format -gt 2 ];then
    echo "$func: image_format must be 1 or 2"
    exit
  fi
  local pool=rbd
  local res=`rbd list|grep -E "^$1$"` 
  echo "$func $image_name ..."
  if [ "$res"x = ""x ];then
    rbd -p $pool create $image_name --size $size --image_format $image_format
  else
    rbd -p $pool resize --allow-shrink --size $size $image_name
  fi
}

#------------ simple test case for v1 and v2 -------------
function test_case()
{
  local func="test_case"
  local mnt=/rbdfuse

  local images;
  #defaul pool : rbd
  local pool=rbd
  local N=1;
  local sizes=(256 512 1024) #MB
  
  echo "$func: umount rbd-fuse"
  umount $mnt

  echo "$func: create images ..."
  for((i=0; i<$N ; i++ ))
  do
    local id=$(($i+1))
    local image_v1="image_v1_$id"
    local image_v2="image_v2_$id"
    images[$i]=$image_v1
    images[$N+$i]=$image_v2
    size=${sizes[$i]}
    create_image $image_v1 $size 1
    create_image $image_v2 $size 2
  done 

  if [ ! -e $mnt ];then
    mkdir $mnt;
  fi
  rbd-fuse -p $pool $mnt;

  echo "$func: fill images ..."
  for((i=0; i<$N ; i++ ))
  do
    local id=$(($i+1))
    local image_v1="image_v1_$id"
    local image_v2="image_v2_$id"
    size=${sizes[$i]}
    echo "fill $image_v1 ..."
    dd conv=notrunc if=/dev/urandom of=$mnt/$image_v1 bs=1M count=$size
    echo "fill $image_v2 ..."
    dd conv=notrunc if=/dev/urandom of=$mnt/$image_v2 bs=1M count=$size
  done 

  sleep 2 # for safe writing...

  get_all_images_online
  echo ${images[*]}|xargs -n 1 echo |read_image_names
  
  export_images

  stop_ceph 
  sleep 2
  check_ceph_service

  echo 0 >$gen_db
  do_gen_database
  recover_images
  cat $image_names|tr -d [:blank:]|xargs -n 1 echo|check_md5sum  
}

init 
clear_image_names
test_case
