fx_version 'cerulean'
game 'gta5'

name 'rhd_pausemenublip'
description 'Daftar lokasi pause map'
author 'RHD TEAM'
version '1.0.0'

lua54 'yes'

shared_script '@ox_lib/init.lua'

client_scripts {
    'client.lua'
}

ui_page 'html/index.html'

files {
    'html/**/*',
    'modules/*'
}
