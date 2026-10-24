# PHP 8.5.12 on Ubuntu: Automated Installation, PHP-FPM and Troubleshooting

**A practical guide for Linux administrators, PHP developers, and DevOps engineers**

I’m sharing my project for building and installing **PHP 8.5.12 from source on Ubuntu**, with PHP CLI, PHP-FPM, OPcache, and a selection of commonly used PHP extensions.

The objective is to provide administrators with a reproducible installation process and greater control over their PHP environment.

🔗 **GitHub repository:**  
https://github.com/djhamzas/php-8.5.12-ubuntu-build

## 1. Project overview

The Bash installation script automates several operations:

- Installing PHP compilation dependencies.
- Downloading the PHP source archive.
- Configuring and compiling PHP from source.
- Installing PHP CLI and PHP-FPM.
- Configuring PHP-FPM as a systemd service.
- Setting up OPcache.
- Creating command-line symlinks.
- Verifying the PHP installation.

The build includes common extensions such as OpenSSL, cURL, mbstring, Intl, GD, PDO, SQLite, MySQL, and PostgreSQL support, subject to the build configuration and required system libraries.

## 2. Apache integration with PHP-FPM

For Apache deployments, PHP can be served through PHP-FPM using `proxy_fcgi`.

The Apache configuration can use a Unix socket, for example:

```apache
<FilesMatch "\.php$">
    SetHandler "proxy:unix:/run/php/php-fpm.sock|fcgi://localhost"
</FilesMatch>

DirectoryIndex index.php index.html
```

Required Apache modules may include:

```bash
sudo a2enmod mpm_event proxy proxy_fcgi setenvif
sudo a2enconf php-fpm
sudo systemctl restart apache2
```

Adapt the socket path and enabled modules to the actual PHP-FPM and Apache configuration on your server.

## 3. Troubleshooting: PHP CLI and Apache report different versions

One issue administrators may encounter is that Apache displays PHP 8.5.12 through `phpinfo()`, while the terminal reports another PHP version.

This can happen because Apache and the shell may use different PHP installations. Apache may use PHP-FPM, while the `php` command resolves to another executable through the shell's `PATH`.

### Step 1 — Run diagnostic commands

Identify the PHP executable selected by the shell:

```bash
type -a php
which php
readlink -f "$(which php)"
```

Check the CLI version and configuration:

```bash
php -v
php -m
php --ini
```

Then explicitly run the PHP binary installed by the source build:

```bash
/usr/local/php-8.5.12/bin/php -v
/usr/local/php-8.5.12/bin/php -m
```

If the explicit binary reports PHP 8.5.12 but `php -v` reports an older version, the issue is likely the executable selected through `PATH`.

### Step 2 — Apply the most likely fix

For the current shell session, prioritize the PHP 8.5.12 binary:

```bash
export PATH="/usr/local/php-8.5.12/bin:$PATH"
hash -r

php -v
php -m
```

If `/usr/local/php` is a valid symlink to the installation, you can instead use:

```bash
export PATH="/usr/local/php/bin:$PATH"
hash -r
```

Verify the results before making persistent changes to your shell configuration.

### Step 3 — Fix the OPcache loading warning

Another possible issue is a warning similar to:

```text
PHP Warning: Failed loading Zend extension 'opcache'
```

In the case I investigated, the configuration contained this directive:

```ini
zend_extension=opcache
```

The configured extension file did not exist at the expected path. However, PHP's output also showed that Zend OPcache was already available in the build.

Locate the directive:

```bash
grep -RniE 'zend_extension.*opcache' \
    /usr/local/php-8.5.12/etc \
    /usr/local/etc/php \
    2>/dev/null
```

In my environment, the result identified:

```text
/usr/local/etc/php/conf.d/10-opcache.ini
```

Edit the file:

```bash
sudo vi /usr/local/etc/php/conf.d/10-opcache.ini
```

Comment out the redundant loading directive:

```ini
;zend_extension=opcache
```

Keep the other OPcache configuration settings, such as `opcache.enable` and `opcache.memory_consumption`, unless there is a separate reason to change them.

**Important:** this correction applies to a build in which OPcache is already available and the extra loading directive is causing the warning. Verify the actual build and extension configuration before applying the change to another environment.

### Step 4 — Verify the correction

Run:

```bash
php -v
php -m
php --ri "Zend OPcache"
```

The expected result is PHP 8.5.12 without the previous loading warning, with Zend OPcache available.

Check PHP-FPM separately:

```bash
sudo systemctl status php-fpm --no-pager
```

If the service has a version-specific name, find it with:

```bash
systemctl list-units --type=service | grep -i php
```

A working CLI does not, by itself, prove that PHP-FPM or Apache is correctly configured. Test all three components independently.

## 4. Important safety considerations

The current script includes cleanup operations that can remove existing PHP packages, configuration directories, binaries, and service definitions.

Before using it:

- Test it on a disposable virtual machine or a non-production server.
- Back up existing PHP configuration and application data.
- Review the script before running it with elevated privileges.
- Validate the build on each Ubuntu release you intend to support.
- Confirm the PHP CLI version, extensions, PHP-FPM service, and Apache integration.

The script should be treated as a starting point for testing and review, not as a universally safe upgrade procedure.

## 5. Community feedback and contributions

I’m sharing this project to exchange practical experience with the Linux, PHP, and DevOps communities.

Feedback, testing reports, and suggestions for improving compatibility, security, and installation safety are welcome.

🔗 **Explore the project on GitHub:**  
https://github.com/djhamzas/php-8.5.12-ubuntu-build

#PHP #Ubuntu #Linux #DevOps #SysAdmin #OpenSource #PHPFPM #Apache #WebDevelopment
