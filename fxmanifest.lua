fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'GS-DroneSystem'
author 'GooberScripts'
description 'Deployable drone with live cam, thermal, spotlight, tracker dart (config-driven)'
version '1.0.0'

shared_scripts {
  'config.lua',
  'shared/utils.lua',
}

client_scripts {
  'client/main.lua',
}

server_scripts {
  'server/main.lua',
}

ui_page 'web/index.html'

files {
  'web/index.html',
  'web/style.css',
  'web/app.js',
  'logo.png',
}

dependencies {
  -- ox_lib is OPTIONAL (script runs without it)
}