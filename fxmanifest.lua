fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'cipher-drone'
author 'XyraL'
description 'Cipher — Drone. Deployable police drone with live cam, thermal, spotlight, tracker darts, shoot-down, and criminal-side jamming counterplay.'
version '2.0.0'

shared_scripts {
  'config.lua',
}

client_scripts {
  'bridge/framework.lua',
  'client/main.lua',
}

server_scripts {
  'bridge/framework.lua',
  'server/main.lua',
}

ui_page 'html/index.html'

files {
  'html/index.html',
  'html/css/style.css',
  'html/js/app.js',
  'logo.png',
}

dependencies {
  -- ox_lib is OPTIONAL (script runs without it)
}
