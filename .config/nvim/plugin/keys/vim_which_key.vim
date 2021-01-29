let g:which_key_map_local = {}
let g:which_key_map_leader  = {
      \ 'name': '+Leader',
      \ }
let g:which_key_map_leader['d'] = {
      \ 'name': '+Delete',
      \'d'   : [':bp|bd #', 'Dell current buffer'],
      \ }

function GetBuffers()
  let buffers = map(filter(copy(getbufinfo()), 'v:val.listed'), 'v:val.bufnr')
  call map(buffers, 'bufname(v:val)' )
  let idx=1
  for i in buffers
    let whichkeyList = []
    let whichkeyDelList = []
    let idxStr = string(idx)
    let airlineCmd = '<Plug>AirlineSelectTab' . idxStr
    let airlineDelCmd = ':bd ' . i
    call add(whichkeyList, airlineCmd)
    "let label = '  ' . fnamemodify(i, ":t:s?index.ts?blabla?")
    let label = '  ' . fnamemodify(i, ":.:s?index??:s?src??")
    call add(whichkeyList, label)
    call add(whichkeyDelList, airlineDelCmd)
    call add(whichkeyDelList, label)
    let g:which_key_map_leader[idxStr] = whichkeyList
    let g:which_key_map_leader['d'][idxStr] = whichkeyDelList
    let idx+=1
  endfor
endfunction

autocmd BufWinEnter * call GetBuffers()


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
let g:which_key_map_leader['|']  = ['<Plug>AirlineSelectPrevTab', 'Previous Buffer']
let g:which_key_map_leader['<Tab>']  = [':b #', 'Toggle Buffers']
let g:which_key_map_leader['s']  = ['<Plug>Sneak_s', 'Sneak next']
let g:which_key_map_leader['S']  = ['<Plug>Sneak_S', 'Sneak Previous']
let g:which_key_map_local['y'] = ['\"+y', 'Yank2clipboard']


"nnoremap <leader><F5> VimspectorStop \| :VimspectorReset<CR>
let g:which_key_map_leader.g = [':FloatermNew lazygit' , 'git']

"let g:which_key_map_leader.d = {
      "\ 'name' : '+Delete' ,
      "\'d'   : [':bp|bd #', 'Dell current buffer'],
      "\'1'   : ['<Plug>AirlineSelectTab1\|:bp|bd #\<CR>', 'tab1'],
      "\'2'   : ['<Plug>AirlineSelectTab2\|:bp|bd #\<CR>', 'tab2'],
      "\'3'   : ['<Plug>AirlineSelectTab3\|:bp|bd #\<CR>', 'tab3'],
      "\'4'   : ['<Plug>AirlineSelectTab4\|:bp|bd #\<CR>', 'tab4'],
      "\'5'   : ['<Plug>AirlineSelectTab5\|:bp|bd #\<CR>', 'tab5'],
      "\'6'   : ['<Plug>AirlineSelectTab6\|:bp|bd #\<CR>', 'tab6'],
      "\'7'   : ['<Plug>AirlineSelectTab7\|:bp|bd #\<CR>', 'tab7'],
      "\'8'   : ['<Plug>AirlineSelectTab8\|:bp|bd #\<CR>', 'tab8'],
      "\'9'   : ['<Plug>AirlineSelectTab9\|:bp|bd #\<CR>', 'tab9'],
      "\ }

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
      \ 'c': [':Pickachu', 'Color Picker'],
      \ }

let g:which_key_map_local.f = {
      \ 'name': '+fzf',
      \ 'p' : [':Files' , 'Files search'],
      \ 'a' : [':Buffers' , 'Buffers search'],
      \ 'f' : [':RG' , 'word search'],
      \ 'l' : [':Lines' , 'Buffers word search'],
      \ 'b' : [':BLines' , 'Current buffer word search'],
      \ 'h' : [':History:' , 'CMD history search'],
      \ }

let g:which_key_map_leader.v = {
      \ 'name' : '+vim' ,
      \ 'e' : [':vsplit $MYVIMRC'    , 'edit'] ,
      \ 's' : [':source $MYVIMRC'    , 'source'] ,
      \ }

let g:which_key_map_local.c = {
      \ 'name' : '+Coc' ,
      \ 'a' : [':CocAction'    , 'Action']                   ,
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

"map <leader>cp :Pickachu<CR>
"map <leader>fr :FloatermNew ranger<CR>
"nnoremap <leader>ev : vsplit $MYVIMRC<CR>
"nnoremap <leader>sv :source $MYVIMRC<CR>
"nnoremap <leader><leader>   :bnext<CR>
"nnoremap <leader>\|   :bprevious<CR>
"nnoremap <silent> <leader><F5> :VimspectorReset<CR>
"vmap <leader>te "+y
"nmap <Leader>1 <Plug>AirlineSelectTab1
"nmap <Leader>2 <Plug>AirlineSelectTab2
"nmap <Leader>3 <Plug>AirlineSelectTab3
"nmap <Leader>4 <Plug>AirlineSelectTab4
"nmap <Leader>5 <Plug>AirlineSelectTab5
"nmap <Leader>6 <Plug>AirlineSelectTab6
"nmap <Leader>7 <Plug>AirlineSelectTab7
"nmap <Leader>8 <Plug>AirlineSelectTab8
"nmap <Leader>9 <Plug>AirlineSelectTab9
"nmap <leader>rn <Plug>(coc-rename)
"xmap <leader>a  <Plug>(coc-codeaction-selected)

""nnoremap <leader>ff fw :Rg<CR>
""nnoremap <leader><F5> VimspectorStop \| :VimspectorReset<CR>
""nmap <Leader>1 <Plug>lightline#bufferline#go(1)
""nmap <Leader>2 <Plug>lightline#bufferline#go(2)
""nmap <Leader>3 <Plug>lightline#bufferline#go(3)
""nmap <Leader>4 <Plug>lightline#bufferline#go(4)
""nmap <Leader>5 <Plug>lightline#bufferline#go(5)
""nmap <Leader>6 <Plug>lightline#bufferline#go(6)
""nmap <Leader>7 <Plug>lightline#bufferline#go(7)
""nmap <Leader>8 <Plug>lightline#bufferline#go(8)
""nmap <Leader>9 <Plug>lightline#bufferline#go(9)
""nmap <Leader>0 <Plug>lightline#bufferline#go(10)
