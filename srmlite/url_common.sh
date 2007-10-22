
checkCertProxy()
{
  if [ ! -e "$1" ]
  then
    echo "Proxy certificate does not exists"
    exit 1
  fi

  if [ ! -f "$1" ]
  then
    echo "Proxy certificate is not a regular file"
    exit 2
  fi

  if [ ! -r "$1" ]
  then
    echo "Permission to read proxy certificate denied"
    exit 3
  fi

}

checkFileSrc()
{
  if [ ! -e "$1" ]
  then
    echo "File does not exists"
    exit 4
  fi

  if [ ! -f "$1" ]
  then
    echo "Not a regular file"
    exit 5
  fi

  if [ ! -r "$1" ]
  then
    echo "Permission to read denied"
    exit 6
  fi
}


checkFileDst()
{
  if [ -e "$1" ]
  then
    echo "File already exists"
    exit 7
  fi

  tmp="$2"

  while [ ! -e "$tmp" ]
  do
    tmp=`dirname $tmp`
  done

  if [ ! -d "$tmp" ]
  then
    echo "Not a directory"
    exit 8
  else
    if [ ! -w "$tmp" ]
    then
      echo "Permission to mkdir denied"
      exit 9
    fi

    result=`mkdir -p $2`
    if [ $? != 0 ]
    then
      echo "$result"
      exit 10
    fi
  fi

  if [ ! -w "$2" ]
  then
    echo "Permission to write denied"
    exit 11
  fi
}

