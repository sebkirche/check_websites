# NAME

check.pl - An automatic page change tester written in Perl.

# VERSION

v0.9.2

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

For each site, you can configure

- `name` the name displayed for a site in outpout / emails.

- `url` an url to retrieve

- one of the following tests:

    - `xpath` a xpath to retrieve in the document on which the comparison is made. Beware if you define the xpath using a browser: sometimes the browser is beautifying / fixing the page structure and you may not understand why your xpath fails for the check. In such case, take a look in the actual raw document retrieved by curl / wget.
    
    - `rx_text` a regex pattern that is run on the document visible body text
    
    - `rx_content` a regex pattern that is run on the document content (e.g. you can match on javascript code).

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

- **-t --test**

    Performs only a test of the configured sites and display a result. No email is sent and data are not persisted.
