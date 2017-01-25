
checkCertProxy()
{
  if [ ! -e "$1" ]
  then
    echo "Proxy certificate does not exist"
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

checkFileLs()
{
  if [ ! -e "$1" ]
  then
    echo "File does not exist"
    exit 4
  fi

  if [ ! -r "$1" ]
  then
    echo "Permission to read denied"
    exit 5
  fi
}

checkFileSrc()
{
  if [ ! -e "$1" ]
  then
    echo "File does not exist"
    exit 6
  fi

  if [ ! -f "$1" ]
  then
    echo "Not a regular file"
    exit 7
  fi

  if [ ! -r "$1" ]
  then
    echo "Permission to read denied"
    exit 8
  fi
}

makeDir()
{
  tmp="$1"

  while [ ! -e "$tmp" ]
  do
    tmp=`dirname $tmp`
  done

  if [ ! -d "$tmp" ]
  then
    echo "Not a directory"
    exit 9
  else
    if [ ! -w "$tmp" ]
    then
      echo "Permission to write denied"
      exit 10
    fi

    result=`mkdir -p $1`
    if [ $? != 0 ]
    then
      echo "$result"
      exit 11
    fi
  fi

  if [ ! -w "$1" ]
  then
    echo "Permission to write denied"
    exit 12
  fi
}

checkFileDst()
{
  if [ -e "$1" ]
  then
    echo "File already exists"
    exit 13
  fi

  makeDir "$2"

  ./makeFile squirrel.config "$1"
}


checkFileDel()
{
  if [ ! -L "$1" ] && [ ! -e "$2" ]
  then
    echo "File does not exist"
    exit 14
  fi

  if [ -e "$2" ] && [ ! -f "$2" ]
  then
    echo "Not a regular file"
    exit 15
  fi

  if [ -e "$2" ] && [ ! -w "$2" ]
  then
    echo "Permission to write denied"
    exit 16
  fi
}

