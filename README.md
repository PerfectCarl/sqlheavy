## Introduction

This is a patched version of SQLHeavy that adds `Database.get_last_error()` that gives you the description of the last SQL error.

The original version of the library is [available here](https://gitorious.org/sqlheavy/sqlheavy/source/8afc3c75673b4de8496e7180b48778ec01e19f96:)

## How to build 
```
git clone https://github.com/PerfectCarl/sqlheavy.git
cd sqlheavy
./autogen.sh
./configure --prefix=/usr
make 
sudo make install
```
