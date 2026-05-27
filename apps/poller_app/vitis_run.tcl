# Requires: hw_server running and KR260 connected via USB/JTAG
connect

targets -set -filter {name =~ "Cortex-A53 #0"}
rst -processor

dow workspace/poller_app/Debug/poller_app.elf
con

puts "INFO: Application loaded and running."
puts "INFO: Open a terminal emulator on the KR260 USB UART port at 115200 baud"
puts "INFO: to see counter output and send Ctrl+C to stop."

disconnect
