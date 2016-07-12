# software version information
{% set geoserver_version = '2.9.0' %}
{% set geoserver_md5 = '805e7371bb682395f0be93142868d854' %}
{% set marlin_tag = '0.7.4' %}
{% set marlin_version = '0.7.4-Unsafe' %}
{% set marlin_md5 = '016472a7481f147ab21e70791781a2af' %}
{% set marlin_java2d_md5 = '4fd3b328413edf3150ae58cb6acbd767' %}
{% set postgres_version = '9.5' %}
{% set postgres_port = pillar["borg_client"]["pgsql_port"] %}

# portable flags
{% set slave_type = "" %}
{% set file_suffix = "" %}
{% if salt['grains.get']('borgslave:sync_server', None) %}
{% set slave_type = "portable" %}
{% set file_suffix = "_portable" %}
{% set postgres_port = '5432' %}
{% endif %}

##############################################################################################################
# Install required common lib
##############################################################################################################
borgpkgs:
    pkg.installed:
        - refresh: False
        - pkgs:
            - unzip
            - python-virtualenv
            - gdal-bin
            - python-dev
            - python3-dev

##############################################################################################################
# Install ssh keys for syncing the state repo and copying files from master
##############################################################################################################
/etc/id_rsa_borg:
    file.managed:
        - source: salt://borgslave-formula/files/id_rsa_borg
        - mode: 600
        - template: jinja

/etc/id_rsa_borg.pub:
    file.managed:
        - source: salt://borgslave-formula/files/id_rsa_borg.pub
        - mode: 644
        - template: jinja

##############################################################################################################
# Create user and add authorized keys for slave server 
##############################################################################################################
# create borg user, to allow portable slave to sync from another slave
{% if slave_type == "" %}
borg:
    group.present:
        - gid: 8000

    user.present:
        - fullname: borg
        - shell: /bin/bash
        - home: /home/borg
        - gid: 8000
        - uid: 8000

/home/borg/.ssh/authorized_keys:
    file.managed:
        - source: salt://borgslave-formula/files/authorized_keys
        - makedirs: True
        - mode: 600
        - user: borg
        - group: borg
        - template: jinja
{% endif %}

##############################################################################################################
# Install nginx for portable slave server
##############################################################################################################
{% if slave_type == "portable" %}
nginx_pkg:
    pkgrepo.managed:
        - ppa: nginx/stable
    pkg.installed:
        - name: nginx-extras

/etc/nginx:
    file.recurse:
        - makedirs: True
        - clean: True
        - source: salt://borgslave-formula/files/nginx

nginx:
    service:
        - running
        - watch:
            - file: /etc/nginx
        - require:
            - pkg: nginx_pkg       
{% endif%}

##############################################################################################################
# Install postgres
##############################################################################################################
# Setup PostgreSQL + PostGIS
postgresql_pkg:
    pkgrepo.managed:
        - humanname: PostgreSQL
        - name: deb http://apt.postgresql.org/pub/repos/apt {{ grains["oscodename"] }}-pgdg main
        - key_url: https://www.postgresql.org/media/keys/ACCC4CF8.asc
    pkg.installed:
        - refresh: True
        - pkgs:
            - postgresql-{{ postgres_version }}-postgis-2.2
            - libpq-dev

/etc/postgresql/{{ postgres_version }}/main/postgresql.conf:
    file.managed:
        - source: salt://borgslave-formula/files/pgmain/postgresql.conf
        - template: jinja
        - makedirs: True
        - context:
            postgres_version: {{ postgres_version }}
            postgres_port: {{ postgres_port }}
        - watch_in:
            - service: postgresql

/etc/postgresql/{{ postgres_version }}/main/pg_hba.conf:
    file.managed:
        - source: salt://borgslave-formula/files/pgmain/pg_hba{{ file_suffix }}.conf
        - template: jinja
        - makedirs: True
        - watch_in:
            - service: postgresql

/etc/postgresql/{{ postgres_version }}/main/slave_create.sql:
    file.managed:
        - source: salt://borgslave-formula/files/pgmain/slave_create.sql
        - template: jinja
        - makedirs: True

postgresql:
    service:
        - running

# check that borg DB is created locally
borg_slave:
    cmd.run:
        - name: "createdb {{ pillar["borg_client"]["pgsql_database"] }} && psql -d {{ pillar["borg_client"]["pgsql_database"] }} -f /etc/postgresql/{{ postgres_version }}/main/slave_create.sql"
        - user: postgres
        - unless: 'psql -l | grep "^ {{ pillar["borg_client"]["pgsql_database"] }}\b"'
        - require:
            - file: /etc/postgresql/{{ postgres_version }}/main/slave_create.sql
            - service: postgresql

# add in oim DB user
'psql -d {{ pillar["borg_client"]["pgsql_database"] }} -c "CREATE ROLE \"{{ pillar["borg_client"]["pgsql_username"] }}\" WITH LOGIN SUPERUSER PASSWORD ''{{ pillar["borg_client"]["pgsql_password"] }}'';"':
    cmd.run:
        - user: postgres
        - unless: 'psql -d {{ pillar["borg_client"]["pgsql_database"] }} -c "SELECT * FROM pg_roles WHERE rolname = ''{{ pillar["borg_client"]["pgsql_username"] }}'';" | grep "^ {{ pillar["borg_client"]["pgsql_username"] }}\b"'
        - require: 
            - cmd: borg_slave

##############################################################################################################
# Install scofflaw
##############################################################################################################
{% if slave_type == "" %}
# client access strategy has changed, disable pg_scofflaw for now

pg_scofflaw.conf:
    file.absent:
        - name: /etc/{% if grains["os_family"] == "Debian" %}supervisor/conf.d/pg_scofflaw.conf{% elif grains["os_family"] == "Arch" %}supervisor.d/pg_scofflaw.ini{% endif %}
        - watch_in:
            - supervisord: pg_scofflaw

pg_scofflaw:
    supervisord:
        - dead

{% endif %}

##############################################################################################################
# Install geoserver
##############################################################################################################
# install self-contained GeoServer instance
geoserverpkgs:
    pkg.installed:
        - refresh: False
        - pkgs:
            - supervisor
            - {% if grains["os_family"] == "Debian" %}openjdk-8-jdk{% elif grains["os_family"] == "Arch" %}jdk8-openjdk{% endif %}

    archive:
        - extracted
        - name: /opt/
        - source: http://downloads.sourceforge.net/project/geoserver/GeoServer/{{ geoserver_version }}/geoserver-{{ geoserver_version }}-bin.zip
        - if_missing: /opt/geoserver-{{ geoserver_version }}/
        - source_hash: md5={{ geoserver_md5 }}
        - archive_format: zip
        - watch_in:
            - supervisord: geoserver
            - file: deploy_geoserver

/opt/geoserver:
    file.symlink:
        - target: /opt/geoserver-{{ geoserver_version }}
        - force: True

# add marlin 2D renderer, it has marginally better performance at high threadcounts
/opt/geoserver/lib/marlin-{{ marlin_version }}.jar:
    file.managed:
        - source: https://github.com/bourgesl/marlin-renderer/releases/download/v{{ marlin_tag }}/marlin-{{ marlin_version }}.jar
        - source_hash: md5={{ marlin_md5 }}
        - require:
            - file: /opt/geoserver

/opt/geoserver/lib/marlin-{{ marlin_version }}-sun-java2d.jar:
    file.managed:
        - source: https://github.com/bourgesl/marlin-renderer/releases/download/v{{ marlin_tag }}/marlin-{{ marlin_version }}-sun-java2d.jar
        - source_hash: md5={{ marlin_java2d_md5 }}
        - require:
            - file: /opt/geoserver

# trash example layers
/opt/geoserver/data_dir/workspaces:
    file.directory:
        - clean: True
        - onchanges:
            - archive: geoserverpkgs
        - require:
            - file: /opt/geoserver
    
/opt/geoserver/data_dir/layergroups:
    file.recurse:
        - source: salt://borgslave-formula/files/layergroups
        - clean: True
        - include_empty: True
        - onchanges:
            - archive: geoserverpkgs
        - require:
            - file: /opt/geoserver

/opt/geoserver/data_dir/gwc-layers:
    file.recurse:
        - source: salt://borgslave-formula/files/gwc-layers
        - clean: True
        - include_empty: True
        - onchanges:
            - archive: geoserverpkgs
        - require:
            - file: /opt/geoserver

# fix default security configuration
/opt/geoserver/data_dir/security:
    file.recurse:
        - source: salt://borgslave-formula/files/security{{ file_suffix }}
        - include_empty: True
        - template: jinja
        - context:
            postgres_port: {{ postgres_port }}
        - watch_in:
            - supervisord: geoserver
        - require:
            - file: /opt/geoserver

# because we set the master PW, out-of-box geoserver will have a broken keystore.
/opt/geoserver/data_dir/security/geoserver.jkecs:
    file.absent:
        - onchanges:
            - archive: geoserverpkgs
        - require:
            - file: /opt/geoserver

# change all of the contact info for each of the GeoServer plugins
/opt/geoserver/data_dir:
    file.recurse:
        - source: salt://borgslave-formula/files/data_dir
        - template: jinja
        - watch_in:
            - supervisord: geoserver
        - require:
            - file: /opt/geoserver

    cmd.run:
        - name: chown -R www-data:www-data /opt/geoserver-{{ geoserver_version }}/data_dir
        - require:
            - file: /opt/geoserver/data_dir

'chown -R www-data:www-data /opt/geoserver-{{ geoserver_version }}; chmod +x /opt/geoserver/bin/*.sh;':
    cmd.run:
        - onchanges:
            - archive: geoserverpkgs
        - require:
            - file: /opt/geoserver

# Last-minute GeoServer hotfixing
geoserver_patch_clone:
    cmd.run:
        - name: "git clone https://github.com/parksandwildlife/geoserver-patch.git /opt/geoserver-patch"
        - unless: "test -d /opt/geoserver-patch && test -d /opt/geoserver-patch/.git" 
        - require:
            - file: /etc/id_rsa_borg

geoserver_patch_sync:
    cmd.run:
        - name: "git pull"
        - cwd: /opt/geoserver-patch
        - require:
            - cmd: geoserver_patch_clone

geoserver_patch_install:
    cmd.run:
        - name: "cp -rf /opt/geoserver-patch/{{ geoserver_version }}/* /opt/geoserver-{{ geoserver_version }}/webapps/geoserver"
        - user: www-data
        - group: www-data
        - onlyif: "test -f /opt/geoserver-patch/{{ geoserver_version }}"
        - watch:
            - cmd: geoserver_patch_sync

# set up supervisor job for GeoServer
geoserver.conf:
    file.managed:
        - name: /etc/{% if grains["os_family"] == "Debian" %}supervisor/conf.d/geoserver.conf{% elif grains["os_family"] == "Arch" %}supervisor.d/geoserver.ini{% endif %}
        - source: salt://borgslave-formula/files/geoserver.conf
        - template: jinja
        - context:
            marlin_version: {{ marlin_version }}
        - require:
            - file: /opt/geoserver
        - watch_in:
            - supervisord: geoserver

##############################################################################################################
# Setup borg state repository
##############################################################################################################
# if a new version of GeoServer has been extracted, clobber the sync state cache!
'rm -rf /opt/dpaw-borg-state':
    cmd.run:
        - onchanges:
            - archive: geoserverpkgs
            - pkg: postgresql_pkg

# init dpaw-borg-state repository
/opt/dpaw-borg-state:
    cmd.run:
        - name: "hg init /opt/dpaw-borg-state"
        - unless: "test -d /opt/dpaw-borg-state && test -d /opt/dpaw-borg-state/.hg" 
        - require:
            - file: /etc/id_rsa_borg

# add in pre-update hook to disable commits to the state repository
/opt/dpaw-borg-state/.hg/denied.sh:
    file.managed:
        - source: salt://borgslave-formula/files/denied.sh

/opt/dpaw-borg-state/.hg/hgrc:
    file.managed:
        - source: salt://borgslave-formula/files/hgrc
        - template: jinja
        - require:
            - virtualenv: /opt/dpaw-borg-state/code/venv

##############################################################################################################
# Setup borg state sync repository
##############################################################################################################
# set up borgslave-sync repository (i.e. sync client code)
/opt/dpaw-borg-state/code:
    cmd.run:
        - name: "git clone {{ pillar['borg_client']['code_repo'] }} /opt/dpaw-borg-state/code"
        - unless: "test -d /opt/dpaw-borg-state/code && test -d /opt/dpaw-borg-state/code/.git" 
        - require:
            - cmd: /opt/dpaw-borg-state

/opt/dpaw-borg-state/code/.env:
    file.managed:
        - source: salt://borgslave-formula/files/env{{ file_suffix }}
        - template: jinja
        - context:
            postgres_port: {{ postgres_port }}
        - require:
            - cmd: /opt/dpaw-borg-state/code

/opt/dpaw-borg-state/code/venv:
    virtualenv.managed:
        - requirements: /opt/dpaw-borg-state/code/requirements.txt
        - require:
            - file: /opt/dpaw-borg-state/code/.env

# set up supervisor job for slave_poll
slave_poll.conf:
    file.managed:
        - name: /etc/{% if grains["os_family"] == "Debian" %}supervisor/conf.d/slave_poll.conf{% elif grains["os_family"] == "Arch" %}supervisor.d/slave_poll.ini{% endif %}
        - source: salt://borgslave-formula/files/slave_poll.conf
        - watch_in:
            - supervisord: slave_poll
        - require:
            - virtualenv: /opt/dpaw-borg-state/code/venv

##############################################################################################################
# Load new configuration and restart geoserver and slave_poll
##############################################################################################################
# kill the geoserver/slave sync instance during a package upgrade
'supervisorctl stop geoserver slave_poll; supervisorctl reread;':
    cmd.run:
        - onchanges:
            - archive: geoserverpkgs
            - file: geoserver.conf
            - file: slave_poll.conf
            {% if slave_type == "" %}
            - file: pg_scofflaw.conf
            {% endif %}

'supervisorctl update':
    cmd.run:
        - onchanges:
            - archive: geoserverpkgs
            - file: slave_poll.conf
            - file: geoserver.conf

geoserver:
    supervisord:
        - running
        - require:
            - service: postgresql

# jetty takes ages to bootstrap, give it time
geoserver_wait:
    cmd.script:
        - source: salt://borgslave-formula/files/wait_until_geoserver_running.sh 
        - require:
            - supervisord: geoserver

# start slave poll, which should kick off the first sync
slave_poll:
    supervisord:
        - running
        - require:
            - supervisord: geoserver
    


