#!/bin/bash

APP_NAME=mktdata_poc

echo "Removing existing app"
sudo rm -rf /lib/firmware/xilinx/${APP_NAME}

echo "Moving new version"
sudo mv ${APP_NAME} /lib/firmware/xilinx/
