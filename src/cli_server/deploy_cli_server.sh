#!/bin/bash -
#===============================================================================
#
#          FILE: deploy_cli_server.sh
#
#         USAGE: ./deploy_cli_server.sh
#
#   DESCRIPTION:
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: Raziel Carvajal-Gomez (), raziel.carvajal@uclouvain.be
#  ORGANIZATION:
#       CREATED: 06/21/2018 15:25
#      REVISION:  ---
#===============================================================================

set -o nounset                              # Treat unset variables as an error

ruby cli_server.rb
