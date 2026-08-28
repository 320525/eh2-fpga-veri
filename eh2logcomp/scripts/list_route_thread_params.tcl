foreach parameter [list_param] {
  set lower [string tolower $parameter]
  if {[string match "*route*thread*" $lower] ||
      [string match "*thread*route*" $lower] ||
      [string match "*maxthreads*" $lower]} {
    puts "$parameter=[get_param $parameter]"
  }
}
exit
