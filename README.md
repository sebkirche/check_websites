# NAME

check.pl - An automatic page change tester written in Perl.

# VERSION

v0.9.1

# SYNOPSIS

check.pl \[options\]

# DESCRIPTION

This is a simple tool that can monitor a list of websites and will send a mail if one had changed.

    A change has been detected in the page of "Your monitored application"
    URL is https://www.yourapp.org/
    
    Diff: @@ -1 +1 @@
    -Version 3.2.2-20200204
    +Version 3.2.3-20200221
    
    
    ---
    Sent by /home/jdoe/dev/perl/check_website/check.pl from jdoe@your_host.localdomain.

Typical usage is to be run periodically from a Cron job.

# OPTIONS

- **-h --help**

    Display a short help.

- **--man**

    Display the full manual.

- **-v --verbose**

    Show verbose messages during processing.

- **-d --debug**

    Activate the debug flag (show SMTP details).

- **-l --list**

    List the sites monitored.
