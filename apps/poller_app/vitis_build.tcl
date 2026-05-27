setws ./workspace

platform create -name mktdata_platform \
    -hw ../../vivado/mktdata_poc.xsa

platform active mktdata_platform

domain create -name freertos_domain \
    -os freertos10_xilinx \
    -proc psu_cortexa53_0

platform generate

app create -name poller_app \
    -platform mktdata_platform \
    -domain freertos_domain \
    -template {Empty Application(C)}

importsources -name poller_app -path ./src

app build -name poller_app

puts "INFO: Build complete — workspace/poller_app/Debug/poller_app.elf"
