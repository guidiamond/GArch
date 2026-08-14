function! CreateFileFolder(file_name)
  " alias to a:file_name (function arg)
  let file_name = a:file_name

  " If file_name already exists stop function
  if !empty(glob(file_name))
    echom file_name . " already exists"
    return 
  endif

  let split_name = split(file_name, "/") " eg: src/abc/teste.vim => [src, abc, teste.vim]
  let fmt_folder_name = join(split_name[0:-2], "/") " eg: [src, abc, teste.vim] => src/abc

  execute "silent !mkdir -p " . fmt_folder_name

  let fmt_file_name = split_name[-1]
  " If a file is found (contains .).  It means create folder + file
  " Else fmt_folder_name = file_name as there are no files (create missing folder)
  if stridx(fmt_file_name, ".") != -1
    execute "silent !touch " . file_name
  else
    let fmt_folder_name = file_name
    execute "silent !mkdir " . fmt_folder_name
  endif

  echom "Creating " . join(split_name, "/")
endfunction

command! -nargs=* -bang MKFF call CreateFileFolder(<q-args>)
