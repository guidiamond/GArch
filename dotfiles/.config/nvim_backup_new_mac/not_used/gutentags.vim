let g:gutentags_file_list_command = 'rg --files'

" Specifically configure what a "new project" is for Gutentags. I had to do this for Javascript projects where you also want Gutentags to re-index since it's also faster to do small projects. If you have a small javascript project inside another project, this will help tracing quickly within the javascript project, since the tag file is smaller to trace and thus it takes Gutentags less time to find your definition you're looking for. Make sure you define this properly.
let g:gutentags_add_default_project_roots = 0
let g:gutentags_project_root = ['package.json', '.git']

" One of the things that annoyed me was that for every new project I would have at work, I had to add the tags and tags.lock file to the .gitignore file every single project so I tried to configure it outside of the git repository so that Git wouldn't track it. You can do this with g:gutentags_cache_dir by configuring it like so:
let g:gutentags_cache_dir = expand('~/.cache/vim/ctags/')

" Gutentags should generate new tags if you just finished writing a new file which you're going to include and use in another file. When you write it, you can immediately jump to its definitions.
let g:gutentags_generate_on_write = 1

" Let Gutentags generate more info for the tags.
"
" Explaining --fields=+ailmnS (info gathered from: $ ctags --list-fields)
"
" a: Access (or export) of class members
"
" i: Inheritance information
"
" l: Language of input file containing tag
"
" m: Implementation information
"
" n: Line number of tag definition
"
" S: Signature of routine (e.g. prototype or parameter list)
let g:gutentags_ctags_extra_args = [
      \ '--tag-relative=yes',
      \ '--fields=+ailmnS',
      \ ]

" If you have used Gutentags and you have looked at the tag files it generates by default, it can be extremely slow because it generated a tag for every line for almost any filetype it can find. Below is a list of globs I personally ignore. I've been doing a lot of large Drupal projects as well which are enormous in files and it takes < 5 seconds to generate my whole tags file.
let g:gutentags_ctags_exclude = [
      \ '*.git', '*.svg', '*.hg',
      \ '*/tests/*',
      \ 'build',
      \ 'dist',
      \ '*sites/*/files/*',
      \ 'bin',
      \ 'node_modules',
      \ 'bower_components',
      \ 'cache',
      \ 'compiled',
      \ 'docs',
      \ 'example',
      \ 'bundle',
      \ 'vendor',
      \ '*.md',
      \ '*-lock.json',
      \ '*.lock',
      \ '*bundle*.js',
      \ '*build*.js',
      \ '.*rc*',
      \ '*.json',
      \ '*.min.*',
      \ '*.map',
      \ '*.bak',
      \ '*.zip',
      \ '*.pyc',
      \ '*.class',
      \ '*.sln',
      \ '*.Master',
      \ '*.csproj',
      \ '*.tmp',
      \ '*.csproj.user',
      \ '*.cache',
      \ '*.pdb',
      \ 'tags*',
      \ 'cscope.*',
      \ '*.css',
      \ '*.less',
      \ '*.scss',
      \ '*.exe', '*.dll',
      \ '*.mp3', '*.ogg', '*.flac',
      \ '*.swp', '*.swo',
      \ '*.bmp', '*.gif', '*.ico', '*.jpg', '*.png',
      \ '*.rar', '*.zip', '*.tar', '*.tar.gz', '*.tar.xz', '*.tar.bz2',
      \ '*.pdf', '*.doc', '*.docx', '*.ppt', '*.pptx',
      \ ]
