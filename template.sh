#!/bin/bash

echo -e "\033[0;32mCalling API for top 10 post...\033[0m"

RVMHTTP="http://localhost:3000/v1/videos/top?month=1&year=2017"
CURLARGS="-f -s -S -k"

TOP_10 = $(curl -s $(RVMHTTP) $(CURLARGS))

echo $TOP_10


# # Build the project.
# hugo # if using a theme, replace with `hugo -t <YOURTHEME>`

# # Go To Public folder
# cd public
# # Add changes to git.
# git add .

# # Commit changes.
# msg="rebuilding site `date`"
# if [ $# -eq 1 ]
#   then msg="$1"
# fi
# git commit -m "$msg"

# # Push source and build repos.
# git push origin master

# # Come Back up to the Project Root
# cd ..