" Time before which key appears (default: 1000 ms)
set timeoutlen=500

let g:which_key_use_floating_win = 0

let g:which_key_map_local = {}
let g:which_key_map_leader  = {
      \ 'name': '+Leader',
      \ }

let g:which_key_map_leader['d'] = {
      \ 'name': '+Delete'
      \ }

function GetBuffers()
  let buffers = map(filter(copy(getbufinfo()), 'v:val.listed'), 'v:val.bufnr')
  call map(buffers, 'bufname(v:val)' )
  let curr_buffer =  bufname("%")
  let idx=1
  for i in buffers

    let label = '  ' . fnamemodify(i, ":.:s?index??:s?src??")
    " Goto Buffer command
    let goto_buffer_cmd = ':b ' . i

    " Delete Buffer command
    let unset_buffer_cmd = 'unlet g:which_key_map_leader' . '[' . string(idx) . ']'
    let unset_buffer_delete_cmd = 'unlet g:which_key_map_leader["d"]' . '[' . string(idx) . ']'
    let delete_buffer_cmd = printf(":bp | bd %s | %s | %s", i, unset_buffer_cmd, unset_buffer_delete_cmd)

    " Set whichkey values
    let g:which_key_map_leader[idx] = [goto_buffer_cmd, label]
    let g:which_key_map_leader['d'][idx] = [delete_buffer_cmd, label]

    " Set whichkey values if it's the current buffer
    if i == curr_buffer
      let g:which_key_map_leader['d']['d'] = ['Bdelete', label]
    endif

    let idx+=1
  endfor
endfunction

let g:which_key_map_leader['d']['r'] = ['BufferLineCloseRight', 'Delete all right buffers']
let g:which_key_map_leader['d']['l'] = ['BufferLineCloseLeft', 'Delete all left buffers']

"let g:which_key_map_leader = {
      "\ 'name': '+Leader',
      "\ '1'   : ['<Plug>AirlineSelectTab1', 'tab1'],
      "\ '2'   : ['<Plug>AirlineSelectTab2', 'tab2'],
      "\ '3'   : ['<Plug>AirlineSelectTab3', 'tab3'],
      "\ '4'   : ['<Plug>AirlineSelectTab4', 'tab4'],
      "\ '5'   : ['<Plug>AirlineSelectTab5', 'tab5'],
      "\ '6'   : ['<Plug>AirlineSelectTab6', 'tab6'],
      "\ '7'   : ['<Plug>AirlineSelectTab7', 'tab7'],
      "\ '8'   : ['<Plug>AirlineSelectTab8', 'tab8'],
      "\ '9'   : ['<Plug>AirlineSelectTab9', 'tab9'],
      "\ }
" Change the colors if you want
highlight default link WhichKey          Operator
highlight default link WhichKeySeperator DiffAdded
highlight default link WhichKeyGroup     Identifier
highlight default link WhichKeyDesc      Function

" Hide status line
autocmd! FileType which_key
autocmd  FileType which_key set laststatus=0 noshowmode noruler
      \| autocmd BufLeave <buffer> set laststatus=2 noshowmode ruler

" let g:which_key_map_leader['\']  = ['<Plug>AirlineSelectNextTab', 'Next Buffer']
" let g:which_key_map_leader['|']  = ['<Plug>AirlineSelectPrevTab', 'Previous Buffer']
" let g:which_key_map_leader['\']  = ['bn', 'Next Buffer']
" let g:which_key_map_leader['|']  = ['bp', 'Previous Buffer']
" let g:which_key_map_leader['<Tab>']  = [':b #', 'Toggle Buffers']
" let g:which_key_map_leader['s']  = ['<Plug>Sneak_s', 'Sneak next']
" let g:which_key_map_leader['S']  = ['<Plug>Sneak_S', 'Sneak Previous']
let g:which_key_map_local['y'] = ['\"+y', 'Yank2clipboard']


"nnoremap <leader><F5> VimspectorStop \| :VimspectorReset<CR>
let g:which_key_map_leader.g = [':FloatermNew lazygit' , 'git']

let g:which_key_map_local.e = [':NvimTreeToggle', 'Nvim tree Toggle']

let g:which_key_map_leader.c = {
      \ 'name': '+NerdCommenter',
      \ 's': ['<Plug>NERDCommenterSexy', 'Sexy'],
      \ 'u': ['<Plug>NERDCommenterUncomment', 'Uncomment'],
      \ 'y': ['<Plug>NERDCommenterUncomment', 'Yank && comment'],
      \ 'c': ['<Plug>NERDCommenterComment', 'Comment'],
      \ '$': ['<Plug>NerdCommenterToEOL', 'to EOL'],
      \ 'A': ['<Plug>NerdCommenterAppend', 'Append to the end'],
      \ }

let g:which_key_map_leader.f = {
      \ 'name': '+fileMngr',
      \ 'r' : [':FloatermNew ranger' , 'ranger'],
      \ 'c': [':VCoolIns ra', 'RGBA color picker'],
      \ 'h': [':VCoolIns h', ':HSL color picker'],
      \ }

let g:which_key_map_local.f = {
      \ 'name': '+Find',
      \ 'a' : [':Telescope buffers' , 'Buffers search'],
      \ 'b' : [':Telescope current_buffer_fuzzy_find' , 'Current buffer word search'],
      \ 'c' : [':Telescope git_commits' , 'Git commits search'],
      \ 'd' : [':Telescope git_branches' , 'Git branches search'],
      \ 'e' : [':Telescope git_status' , 'Git diff search'],
      \ 'f' : [':Telescope live_grep' , 'word search'],
      \ 'h' : [':Telescope search_history' , 'CMD history search'],
      \ 'l' : [':Lines' , 'Buffers word search'],
      \ 'p' : [':Telescope fd fd_command=fd,--hidden,--files prompt_prefix=🔍' , 'Files search'],
      \ 's' : [':Telescope git_stash' , 'Git stash search'],
      \ 't' : [':Telescope tags' , 'Tags search'],
      \ }

let g:which_key_map_leader.v = {
      \ 'name' : '+vim' ,
      \ 'e' : [':vsplit $MYVIMRC'    , 'edit'] ,
      \ 's' : [':source $MYVIMRC'    , 'source'] ,
      \ }

" \ 'a' : [':CocAction'    , 'Action']                   ,
let g:which_key_map_local.c = {
      \ 'name' : '+Coc' ,
      \ 'a' : ['<Plug>(coc-codeaction)'    , 'Action']                   ,
      \ 'c' : [':CocList commands'    , 'Commands']                  ,
      \ 'd' : [':CocList diagnostics'    , 'Diagnostics']               ,
      \ 'l' : [':CocList'    , 'List']                      ,
      \ 'o' : ['OR'    , 'Organize Imports']          ,
      \ 'f' : ['FXSCSS'    , 'Scss fix for (class/name)']          ,
      \ 'm' : [':CocList marketplace'    , 'Marketplace']          ,
      \ 'p' : [':CocListResume'    , 'List Resume']               ,
      \ 'r' : [':CocCommand workspace.renameCurrentFile'    , 'Rename current file']       ,
      \ 'R' : ['<Plug>(coc-rename)'    , 'Rename var/function']       ,
      \ }

call GetBuffers()
call which_key#register('\', "g:which_key_map_leader")
call which_key#register('<space>', "g:which_key_map_local")

