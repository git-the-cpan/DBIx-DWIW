## $Source: /CVSROOT/yahoo/finance/lib/perl/PackageMasters/DBIx-DWIW/DWIW.pm,v $
##
## $Id: DWIW.pm,v 1.73 2002/03/20 00:27:33 jzawodn Exp $

package DBIx::DWIW;

use 5.005;
use strict;
use vars qw[$VERSION $SAFE];
use DBI;
use Carp;
use Sys::Hostname;  ## for reporting errors
use Time::HiRes;    ## for fast timeouts

$VERSION = '0.21';
$SAFE    = 1;

=head1 NAME

DBIx::DWIW - Robust and simple DBI wrapper to Do What I Want (DWIW)

=head1 SYNOPSIS

When used directly:

  use DBIx::DWIW;

  my $db = DBIx::DWIW->Connect(DB   => $database,
                               User => $user,
                               Pass => $password,
                               Host => $host);

  my @records = $db->Array("select * from foo");

When sub-classed for full functionality:

  use MyDBI;  # class inherits from DBIx::DWIW

  my $db = MyDBI->Connect('somedb') or die;

  my @records = $db->Hashes("SELECT * FROM foo ORDER BY bar");

=head1 DESCRIPTION

NOTE: This module is currently specific to MySQL, but needn't be.  We
just haven't had a need to talk to any other database server.

DBIx::DWIW was developed (over the course of roughly 1.5 years) in
Yahoo! Finance (http://finance.yahoo.com/) to suit our needs.  Parts
of the API may not make sense and the documentation may be lacking in
some areas.  We've been using it for so long (in one form or another)
that these may not be readily obvious to us, so feel free to point
that out.  There's a reason the version number is currently < 1.0.

This module was B<recently> extracted from Yahoo-specific code, so
things may be a little strange yet while we smooth out any bumps and
blemishes left over form that.

DBIx::DWIW is B<intended to be sub-classed>.  Doing so will give you
all the benefits it can provide and the ability to easily customize
some of its features.  You can, of course, use it directly if it meets
your needs as-is.  But you'll be accepting its default behavior in
some cases where it may not be wise to do so.

The DBIx::DWIW distribution comes with a sample sub-class in the file
C<examples/MyDBI.pm> which illustrates some of what you might want to
do in your own class(es).

This module provides three main benefits:

=head2 Centralized Configuration

Rather than store the various connection parameters (username,
password, hostname, port number, database name) in each and every
script or application which needs them, you can easily put them in
once place--or even generate them on the fly by writing a bit of
custom cdoe.

If this is all you need, consider looking at Brian Aker's fine
C<DBIx::Password> module on the CPAN.  It may be sufficient.

=head2 API Simplicity

Taking a lesson from Python (gasp!), this module promotes one obvious
way to do most things.  If you want to run a query and get the results
back as a list of hashrefs, there's one way to do that.  The API may
sacrifice speed in some cases, but new users can easily learn the
simple and descriptive method calls.  (Nobody is forcing you to use
it.)

=head2 Fault Tolerance

Databases sometimes go down.  Networks flake out.  Bad stuff
happens. Rather than have your application die, DBIx::DWIW provides a
way to handle outages.  You can build custom wait/retry/fail logic
which does anything you might want (such as ringing your pager or
sending e-mail).

=head1 DBIx::DWIW CLASS METHODS

The following methods are available from DBIx::DWIW objects.  Any
function or method not documented should be considered private.  If
you call it, your code may break someday and it will be B<your> fault.

The methods follow the Perl tradition of returning false values when
an error cocurs (an usually setting $@ with a descriptive error
message).

Any method which takes an SQL query string can also be passed bind
values for any placeholders in the query string:

  C<$db->Hashes("SELECT * FROM foo WHERE id = ?", $id);

Any method which takes an SQL query string can also be passed a
prepared DWIW statement handle:

  C<$db->Hashes($sth, $id);

Any method which takes an SQL query string will internally call DBI's
prepare_cached. This ensures that a memory leak does not occur from
repeatedly preparing the same SQL string. Note that calling a method
which accepts an SQL query string while another method using the same SQL
query string is active will cause the first statement to be reset.

=over

=cut

##
## This is the cache of currently-open connections, filled with
##       $CurrentConnections{host,user,password,db} = $db
##
my %CurrentConnections;

##
## Autoload to trap method calls that we haven't defined.  The default
## (when running in unsafe mode) behavior is to check $dbh to see if
## it can() field the call.  If it can, we call it.  Otherwise, we
## die.
##

use vars '$AUTOLOAD';

sub AUTOLOAD
{
    my $method = $AUTOLOAD;
    my $self   = shift;

    $method =~ s/.*:://;  ## strip the package name

    my $orig_method = $method;

    if ($self->{SAFE})
    {
        if (not $method =~ s/^dbi_//)
        {
            $@ = "undefined or unsafe method ($orig_method) called";
            Carp::croak("$@");
        }
    }

    if ($self->{DBH} and $self->{DBH}->can($method))
    {
        $self->{DBH}->$method(@_);
    }
    else
    {
        Carp::croak("undefined method ($orig_method) called");
    }
}

##
## Allow the user to explicity tell us if they want SAFE on or off.
##

sub import
{
    my $class = shift;

    while (my $arg = shift @_)
    {
        if ($arg eq 'unsafe')
        {
            $SAFE = 0;
        }
        elsif ($arg eq 'safe')
        {
            $SAFE = 1;
        }
        else
        {
            warn "unknown use argument: $arg";
        }
    }
}

=item Connect()

The C<Connect()> constructor creates and returns a database connection
object through which all database actions are conducted. On error, it
will call C<die()>, so you may want to C<eval {...}> the call.  The
C<NoAbort> option (described below) controls that behavior.

C<Connect()> accepts ``hash-style'' key/value pairs as arguments.  The
arguments which is recognizes are:

=over

=item Host

The name of the host to connect to. Use C<undef> to force a socket
connection on the local machine.

=item User

The database to user to authenticate as.

=item Pass

The password to authenticate with.

=item DB

The name of the database to use.

=item Socket

NOT IMPLEMENTED.

The path to the Unix socket to use.

=item Port

The port number to connect to.

=item Proxy

Set to true to connect to a DBI::ProxyServer proxy.  You'll also need
to set ProxyHost, ProxyKey, and ProxyPort.  You may also want to set
ProxyKey and ProxyCypher.

=item ProxyHost

The hostname name of the proxy server.

=item ProxyPort

The port number on which the proxy is listening.  This is probably
different than the port number on which the database server is
listening.

=item ProxyKey

If the proxy server you're using requires encryption, supply the
encryption key (as a hex string).

=item ProxyCipher

If the proxy server requires encryption, supply the name of the
package which provies encryption.  Typically this will be something
like C<Crypt::DES> or C<Crypt::Blowfish>.

=item Unique

A boolean which controls connection reuse.

If false (the default), multiple C<Connect>s with the same connection
parameters (User, Pass, DB, Host) will return the same open
connection. If C<Unique> is true, it will return a connection distinct
from all other connections.

If you have a process with an active connection that fork(s), be aware
that you can NOT share the connection between the parent and child.
Well, you can if you're REALLY CAREFUL and know what you're doing.
But don't do it.

Instead, acquire a new connection in the child. Be sure to set this
flag when you do, or you'll end up with the same connection and spend
a lot of time pulling your hair out over why the code does mysterous
things.

=item Verbose

Turns verbose reporting on.  See C<Verbose()>.

=item Quiet

Turns off warning messages.  See C<Quiet()>.

=item NoRetry

If true, the C<Connect()> will fail immediately if it can't connect to
the database. Normally, it will retry based on calls to
C<RetryWait()>.  C<NoRetry> affects only C<Connect>, and has no effect
on the fault-tolerance of the package once connected.

=item NoAbort

If there is an error in the arguments, or in the end the database
can't be connected to, C<Connect()> normally prints an error message
and dies. If C<NoAbort> is true, it will put the error string into
C<$@> and return false.

=item Timeout

The amount of time (in seconds) after which C<Connect()> will give up
and return.  You may use fractional seconds, such as 0.5, 1.0, 6.9, or
whatever.  A Timeout of zero is the same as not having one at all.

If you set the timeout, you probably also want to set C<NoRetry> to a
true value.  Otherwise you'll be surprised when a server is down and
your retry logic is running.

=back

There are a minimum of four components to any database connection: DB,
User, Pass, and Host. If any are not provided, there may be defaults
that kick in. A local configuration package, such as the C<MyDBI>
example class that comes with DBIx::DWIW, may provide appropriate
default connection values for several database. In such a case, a
client my be able to simply use:

    my $db = MyDBI->Connect(DB => 'Finances');

to connect to the C<Finances> database.

as a convenience, you can just give the database name:

    my $db = MyDBI->Connect('Finances');

See the local configuration package appropriate to your installation
for more information about what is and isn't preconfigured.

=cut

sub Connect($@)
{
    my $class = shift;
    my $use_slave_hack = 0;
    my $config_name;

    ##
    ## If the user asks for a slave connection like this:
    ##
    ##   Connect('Slave', 'ConfigName')
    ##
    ## We'll try caling FindSlave() to find a slave server.
    ##
    if (@_ == 2 and ($_[0] eq 'Slave' or $_[0] eq 'ReadOnly'))
    {
        $use_slave_hack = 1;
        shift;
    }

    my %Options;

    ##
    ## Handle $self->Connect('SomeConfig') or any odd number
    ##
    if (@_ % 2 and $class->LocalConfig($_[0]))
    {
        my $arg = shift;
        $config_name = $arg;
        %Options = (%{$class->LocalConfig($arg)}, @_);
    }
    else
    {
        %Options = @_;
    }

    ##
    ## Expecting hash-style arguments.
    ##
    if (@_ % 2)
    {
        die "bad number of arguments to Connect -- " . join " ", @_;
    }

    my $UseSlave = delete($Options{UseSlave});

    if ($use_slave_hack)
    {
        $UseSlave = 1;
    }

    ## Find a slave to use, if we can.

    if ($UseSlave)
    {
        if ($class->can('FindSlave'))
        {
            %Options = $class->FindSlave(%Options);
        }
        else
        {
            warn "$class doesn't know how to find slaves";
        }
    }

    ##
    ## Fetch the arguments.
    ## Allow 'Db' for 'DB'.
    ##
    my $DB       =  delete($Options{DB})   || $class->DefaultDB();
    my $User     =  delete($Options{User}) || $class->DefaultUser($DB);
    my $Password =  delete($Options{Pass}) || $class->DefaultPass($DB);
    my $Port     =  delete($Options{Port}) || $class->DefaultPort($DB);
    my $Unique   =  delete($Options{Unique});
    my $Retry    = !delete($Options{NoRetry});
    my $Quiet    =  delete($Options{Quiet});
    my $NoAbort  =  delete($Options{NoAbort});
    my $Verbose  =  delete($Options{Verbose}); # undef = no change
                                               # true  = on
                                               # false = off
    ## allow empty passwords
    $Password = $class->DefaultPass($DB, $User) if not defined $Password;


    $config_name = $DB unless defined $config_name;

    ## respect the DB_DOWN hack
    $Quiet = 1 if $ENV{DB_DOWN};

    ##
    ## Host parameter is special -- we want to recognize
    ##    Host => undef
    ## as being "no host", so we have to check for its existence in the hash,
    ## and default to nothing ("") if it exists but is empty.
    ##
    my $Host;
    if (exists $Options{Host})
    {
        $Host =  delete($Options{Host}) || "";
    }
    else
    {
        $Host = $class->DefaultHost($DB) || "";
    }

    if (not $DB)
    {
        $@ = "missing DB parameter to Connect";
        die $@ unless $NoAbort;
        return ();
    }

    if (not $User)
    {
        $@ = "missing User parameter to Connect";
        die $@ unless $NoAbort;
        return ();
    }

    if (not defined $Password)
    {
        $@ = "missing Pass parameter to Connect";
        die $@ unless $NoAbort;
        return ();
    }

#      if (%Options)
#      {
#          my $keys = join(', ', keys %Options);
#          $@ = "bad parameters [$keys] to Connect()";
#          die $@ unless $NoAbort;
#          return ();
#      }

    my $myhost = hostname();
    my $desc;

    if (defined $Host)
    {
        $desc = "connection to $Host\'s MySQL server from $myhost";
    }
    else
    {
        $desc = "local connection to MySQL server on $myhost";
    }

    ## we're gonna build the dsn up incrementally...
    my $dsn;

    ## proxy details
    ##
    ## This can be factored together once I'm sure it is working.

    # DBI:Proxy:cipher=Crypt::DES;key=$key;hostname=$proxy_host;port=8192;dsn=DBI:mysql:$db:$host

    if ($Options{Proxy})
    {
        if (not ($Options{ProxyHost} and $Options{ProxyPort}))
        {
            $@ = "ProxyHost and ProxyPort are required when Proxy is set";
            die $@ unless $NoAbort;
            return ();
        }

        $dsn = "DBI:Proxy";

        my $proxy_port = $Options{ProxyPort};
        my $proxy_host = $Options{ProxyHost};

        if ($Options{ProxyCipher} and $Options{ProxyKey})
        {
            my $proxy_cipher = $Options{ProxyCipher};
            my $proxy_key    = $Options{ProxyKey};

            $dsn .= ":cipher=$proxy_cipher;key=$proxy_key";
        }

        $dsn .= ";hostname=$proxy_host;port=$proxy_port";
        $dsn .= ";dsn=DBI:mysql:$DB:$Host;mysql_client_found_rows=1";
    }
    else
    {
        if ($Port)
        {
            $dsn .= "DBI:mysql:$DB:$Host;port=$Port;mysql_client_found_rows=1";
        }
        else
        {
            $dsn .= "DBI:mysql:$DB:$Host;mysql_client_found_rows=1";
        }
    }

    print "DSN: $dsn\n" if $ENV{DEBUG};

    ##
    ## If we're not looking for a unique connection, and we already have
    ## one with the same options, use it.
    ##
    if (not $Unique)
    {
        if (my $db = $CurrentConnections{$dsn})
        {
            if (defined $Verbose)
            {
                $db->{VERBOSE} = $Verbose;
            }

            return $db;
        }
    }

    my $self = {
                DB         => $DB,
                DBH        => undef,
                DESC       => $desc,
                HOST       => $Host,
                PASS       => $Password,
                QUIET      => $Quiet,
                RETRY      => $Retry,
                UNIQUE     => $Unique,
                USER       => $User,
                PORT       => $Port,
                VERBOSE    => $Verbose,
                SAFE       => $SAFE,
                DSN        => $dsn,
                TIMEOUT    => 0,
                RetryCount => 0,
               };

    $self = bless $self, $class;

    if ($ENV{DBIxDWIW_VERBOSE})
    {
        $self->{VERBOSE} = 1;
    }

    my $dbh;
    my $done = 0;

    while (not $done)
    {
        local($SIG{PIPE}) = 'IGNORE';

        ## If the user wants a timeout, we need to set that up and do
        ## it here.  This looks complex, but it's really a no-op
        ## unless the user wants it.
        ##
        ## Notice that if a timeout is hit, then the RetryWait() stuff
        ## will never have a chance to run.  That's good, but we need
        ## to make sure that users will expect that.

        if ($self->{TIMEOUT})
        {
            eval
            {
                local $SIG{ALRM} = sub { die "alarm\n" };

                Time::HiRes::alarm($self->{TIMEOUT});
                $dbh = DBI->connect($dsn, $User, $Password, { PrintError => 0 });
                Time::HiRes::alarm(0);
            };
            if ($@ eq "alarm\n")
            {
                $@ = "connection timeout ($self->{TIMEOUT} sec passed)";
                return undef;
            }
        }
        else
        {
            $dbh = DBI->connect($dsn, $User, $Password, { PrintError => 0 });
        }

        if (not ref $dbh)
        {
            if ($Retry
                and
                ($DBI::errstr =~ m/can\'t connect/i
                 or
                 $DBI::errstr =~ m/Too many connections/i)
                and
                $self->RetryWait($DBI::errstr))
            {
                $done = 0; ## Heh.
            }
            else
            {
                warn "$DBI::errstr" if not $Quiet;
                $@ = "can't connect to database: $DBI::errstr";
                die $@ unless $NoAbort;
                $self->_OperationFailed();
                return ();
            }
        }
        else
        {
            $done = 1;  ## it worked!
        }
    } ## end while not done

    ##
    ## We got through....
    ##
    $self->_OperationSuccessful();
    $self->{DBH} = $dbh;

    ##
    ## Save this one if it's not to be unique.
    ##
    $CurrentConnections{$dsn} = $self if not $Unique;
    return $self;
}

*new = \&Connect;

=item Timeout()

Like the Timeout argument to Connect(), the amount of time (in
seconds) after which queries will give up and return.  You may use
fractional seconds, such as 0.5, 1.0, 6.9, or whatever.  A Timeout of
zero is the same as not having one at all.

C<Timeout()> called with any (or no) arguments will return the current
timeout value.

=cut

sub Timeout(;$)
{
    my $self = shift;
    my $time = shift;

    if (defined $time)
    {
        $self->{TIMEOUT} = $time;
    }

    print "TIMEOUT SET TO: $self->{TIMEOUT}\n" if $self->{VERBOSE};

    return $self->{TIMEOUT};
}

=item Disconnect()

Closes the connection. Upon program exit, this is called automatically
on all open connections. Returns true if the open connection was
closed, false if there was no connection, or there was some other
error (with the error being returned in C<$@>).

=cut

sub Disconnect($)
{
    my $self = shift;

    if (not $self->{UNIQUE})
    {
        delete $CurrentConnections{$self->{DSN}};
    }

    if (not $self->{DBH})
    {
        $@ = "not connected in Disconnect()";
        return ();
    }

    ## clean up a lingering sth if there is one...

    if (defined $self->{RecentExecutedSth})
    {
        $self->{RecentExecutedSth}->finish();
    }

    if (not $self->{DBH}->disconnect())
    {
        $@ = "couldn't disconnect (or wasn't disconnected)";
        $self->{DBH} = undef;
        return ();
    }
    else
    {
        $@ = "";
        $self->{DBH} = undef;
        return 1;
    }
}

sub DESTROY($)
{
    my $self = shift;
    $self->Disconnect();
}

=item Quote(@values)

Calls the DBI C<quote()> function on each value, returning a list of
properly quoted values. As per quote(), NULL will be returned for
items that are not defined.

=cut

sub Quote($@)
{
    my $self  = shift;
    my $dbh   = $self->dbh();
    my @ret;

    for my $item (@_)
    {
        push @ret, $dbh->quote($item);
    }

    if (wantarray)
    {
        return @ret;
    }

    if (@ret > 1)
    {
        return join ', ', @ret;
    }

    return $ret[0];
}

=pod

=item ExecuteReturnCode()

Returns the return code from the most recently Execute()d query.  This
is what Execute() returns, so there's little reason to call it
direclty.  But it didn't used to be that way, so old code may be
relying on this.

=cut

sub ExecuteReturnCode($)
{
    my $self = shift;
    return $self->{ExecuteReturnCode};
}

## Private version of Execute() that deals with statement handles
## ONLY.  Given a staement handle, call execute and insulate it from
## common problems.

sub _Execute()
{
    my $self      = shift;
    my $statement = shift;
    my @bind_vals = @_;

    if (not ref $statement)
    {
        $@ = "non-reference passed to _Execute()";
        warn "$@" unless $self->{QUIET};
        return ();
    }

    my $sth = $statement->{DBI_STH};

    print "_EXECUTE: $statement->{SQL}: ", join(" | ", @bind_vals), "\n" if $self->{VERBOSE};

    ##
    ## Execute the statement. Retry if requested.
    ##
    my $done = 0;

    while (not $done)
    {
        local($SIG{PIPE}) = 'IGNORE';

        ## If the user wants a timeout, we need to set that up and do
        ## it here.  This looks complex, but it's really a no-op
        ## unless the user wants it.
        ##
        ## Notice that if a timeout is hit, then the RetryWait() stuff
        ## will never have a chance to run.  That's good, but we need
        ## to make sure that users will expect that.

        if ($self->{TIMEOUT})
        {
            eval
            {
                local $SIG{ALRM} = sub { die "alarm\n" };

                Time::HiRes::alarm($self->{TIMEOUT});
                $self->{ExecuteReturnCode} = $sth->execute(@bind_vals);
                Time::HiRes::alarm(0);
            };
            if ($@ eq "alarm\n")
            {
                $@ = "query timeout ($self->{TIMEOUT} sec passed)";
                return undef;
            }
        }
        else
        {
            $self->{ExecuteReturnCode} = $sth->execute(@bind_vals);
        }

        ## Otherwise, if it's an error that we know is "retryable" and
        ## the user wants to retry (based on the RetryWait() call),
        ## we'll try again.

        if (not defined $self->{ExecuteReturnCode})
        {
            my $err = $self->{DBH}->errstr;
            if ($self->{RETRY}
                and
                ($err =~ m/Lost connection/
                 or
                 $err =~ m/server has gone away/
                 or
                 $err =~ m/Server shutdown in progress/
                )
                and
                $self->RetryWait($err))
            {
                next;
            }

            ## It is really an error that we cannot (or should not)
            ## retry, so spit it out if needed.

            $@ = "$err [in prepared statement]";
            Carp::cluck "execute of prepared statement returned undef [$err]" if $self->{VERBOSE};
            $self->_OperationFailed();
            return undef;
        }
        else
        {
            $done = 1;
        }
    }

    ##
    ## Got through.
    ##
    $self->_OperationSuccessful();

    print "EXECUTE successful\n" if $self->{VERBOSE};

    ##
    ## Save this as the most-recent successful statement handle.
    ##
    $self->{RecentExecutedSth} = $sth;

    ##
    ## Execute worked -- return the statement handle.
    ##
    return $self->{ExecuteReturnCode}
}

## Public version of Execute that deals with SQL only and calls
## _Execute() to do the real work.

=item Execute($sql)

Executes the given SQL, returning true if successful, false if not
(with the error in C<$@>).

C<Do()> is a synonym for C<Execute()>

=cut

sub Execute($$@)
{
    my $self      = shift;
    my $sql       = shift;
    my @bind_vals = @_;

    if (not $self->{DBH})
    {
        $@ = "not connected in Execute()";
        Carp::croak "not connected to the database" unless $self->{QUIET};
    }

    my $sth;

    if (ref $sql)
    {
        $sth = $sql;
    }
    else
    {
        print "EXECUTE> $sql\n" if $self->{VERBOSE};
        $sth = $self->Prepare($sql);
    }

    return $sth->Execute(@bind_vals);
}

##
## Do is a synonynm for Execute.
##
*Do = \&Execute;

=item Prepare($sql)

Prepares the given sql statement, but does not execute it (just like
DBI). Instead, it returns a statement handle C<$sth> that you can
later execute by calling its Execute() method:

  my $sth = $db->Prepare("INSERT INTO foo VALUES (?, ?)");

  $sth->Execute($a, $b);

The statement handle returned is not a native DBI statement
handle. It's a DBIx::DWIW::Statement handle.

=cut

sub Prepare($$;$)
{
    my $self = shift;
    my $sql  = shift;

    if (not $self->{DBH})
    {
        $@ = "not connected in Prepare()";

        if (not $self->{QUIET})
        {
            carp scalar(localtime) . ": not connected to the database";
        }
        return ();
    }

    $@ = "";  ## ensure $@ is clear if not error.

    if ($self->{VERBOSE})
    {
        print "PREPARE> $sql\n";
    }

    my $dbi_sth = $self->{DBH}->prepare($sql);

#      my $dbi_sth;
#      if ($ENV{DWIW_NO_STH_CACHING}) {
#        $dbi_sth = $self->{DBH}->prepare($sql);
#      }
#      else {
#        $dbi_sth = $self->{DBH}->prepare_cached($sql, {}, 1);
#      }

    ## Build the new statment handle object and bless it into
    ## DBIx::DWIW::Statment.  Then return that object.

    $self->{RecentPreparedSth} = $dbi_sth;

    my $sth = {
                SQL     => $sql,      ## save the sql
                DBI_STH => $dbi_sth,  ## the real statement handle
                PARENT  => $self,     ## remember who created us
              };

    return bless $sth, 'DBIx::DWIW::Statement';
}

=item RecentSth()

Returns the DBI statement handle (C<$sth>) of the most-recently
I<successfuly executed> statement.

=cut

sub RecentSth($)
{
    my $self = shift;
    return $self->{RecentExecutedSth};
}

=item RecentPreparedSth()

Returns the DBI statement handle (C<$sth>) of the most-recently
prepared DBI statement handle (which may or may not have already been
executed).

=cut

sub RecentPreparedSth($)
{
    my $self = shift;
    return $self->{RecentPreparedSth};
}

=item InsertedId()

Returns the C<mysql_insertid> associated with the most recently
executed statement. Returns nothing if there is none.

Synonyms: C<InsertID()>, C<LastInsertID()>, and C<LastInsertId()>

=cut

sub InsertedId($)
{
    my $self = shift;
    if ($self->{RecentExecutedSth}
        and
        defined($self->{RecentExecutedSth}->{mysql_insertid}))
    {
        return $self->{RecentExecutedSth}->{mysql_insertid};
    }
    else
    {
        return ();
    }
}

## Aliases for people who like Id or ID and Last or not Last. :-)

*InsertID     = \&InsertedId;
*LastInsertID = \&InsertedId;
*LastInsertId = \&InsertedId;

=item RowsAffected()

Returns the number of rows affected for the most recently executed
statement.  This is valid only if it was for a non-SELECT. (For
SELECTs, count the return values). As per the DBI, the -1 is returned
if there was an error.

=cut

sub RowsAffected($)
{
    my $self = shift;
    if ($self->{RecentExecutedSth})
    {
        return $self->{RecentExecutedSth}->rows();
    }
    else
    {
        return ();
    }
}

=item RecentSql()

Returns the sql of the most recently executed statement.

=cut

sub RecentSql($)
{
    my $self = shift;
    if ($self->{RecentExecutedSth})
    {
        return $self->{RecentExecutedSth}->{Statement};
    }
    else
    {
        return ();
    }
}

=item PreparedSql()

Returns the sql of the most recently prepared statement.
(Useful for showing sql that doesn't parse.)

=cut

sub PreparedSql($)
{
    my $self = shift;
    if ($self->{RecentpreparedSth})
    {
        return $self->{RecentPreparedSth}->{SQL};
    }
    else
    {
        return ();
    }
}

=item Hash($sql)

A generic query routine. Pass an SQL statement that returns a single
record, and it will return a hashref with all the key/value pairs of
the record.

The example at the bottom of page 50 of DuBois's I<MySQL> book would
return a value similar to:

  my $hashref = {
     last_name  => 'McKinley',
     first_name => 'William',
  };

On error, C<$@> has the error text, and false is returned. If the
query doesn't return a record, false is returned, but C<$@> is also
false.

Use this routine only if the query will return a single record.  Use
C<Hashes()> for queries that might return multiple records.

Because calling C<Hashes()> on a larger recordset can use a lot of
memory, you may wish to call C<Hash()> once with a valid query and
call it repetedly with no SQL to retrieve records one at a time.
It'll take more CPU to do this, but it is more memory efficient:

  $db->Hash("SELECT * FROM big_table");

  while (defined $stuff = $db->Hash())
  {
      # ... do stuff
  }

This seems like it breaks the priciple of having only one obvious way
to do things with this package.  But it's really not all that obvious,
now is it? :-)

=cut

sub Hash($$@)
{
    my $self      = shift;
    my $sql       = shift || "";
    my @bind_vals = @_;

    if (not $self->{DBH})
    {
        $@ = "not connected in Hash()";
        return ();
    }

    print "HASH: $sql\n" if ($self->{VERBOSE});

    my $result = undef;

    if ($sql eq "" or $self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};
        $result = $sth->fetchrow_hashref;

        if (not $result)
        {
            if ($sth->err)
            {
                $@ = $sth->errstr . " [$sql] ($sth)";
            }
            else
            {
                $@ = "";
            }
        }
    }
    return $result ? $result : ();
}

=item Hashes($sql)

A generic query routine. Given an SQL statement, returns a list of
hashrefs, one per returned record, containing the key/value pairs of
each record.

The example in the middle of page 50 of DuBois's I<MySQL> would return
a value similar to:

 my @hashrefs = (
  { last_name => 'Tyler',    first_name => 'John',    birth => '1790-03-29' },
  { last_name => 'Buchanan', first_name => 'James',   birth => '1791-04-23' },
  { last_name => 'Polk',     first_name => 'James K', birth => '1795-11-02' },
  { last_name => 'Fillmore', first_name => 'Millard', birth => '1800-01-07' },
  { last_name => 'Pierce',   first_name => 'Franklin',birth => '1804-11-23' },
 );

On error, C<$@> has the error text, and false is returned. If the
query doesn't return a record, false is returned, but C<$@> is also
false.

=cut

sub Hashes($$@)
{
    my $self      = shift;
    my $sql       = shift;
    my @bind_vals = @_;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected in Hashes()";
        return ();
    }

    print "HASHES: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};

        while (my $ref = $sth->fetchrow_hashref)
        {
            push @records, $ref;
        }
    }
    return @records;
}

=item Array($sql)

Similar to C<Hash()>, but returns a list of values from the matched
record. On error, the empty list is returned and the error can be
found in C<$@>. If the query matches no records, the an empty list is
returned but C<$@> is false.

The example at the bottom of page 50 of DuBois's I<MySQL> would return
a value similar to:

  my @array = ( 'McKinley', 'William' );

Use this routine only if the query will return a single record.  Use
C<Arrays()> or C<FlatArray()> for queries that might return multiple
records.

=cut

sub Array($$@)
{
    my $self      = shift;
    my $sql       = shift;
    my @bind_vals = @_;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected Array()";
        return ();
    }

    print "ARRAY: $sql\n" if $self->{VERBOSE};

    my @result;

    if ($self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};
        @result = $sth->fetchrow_array;

        if (not @result)
        {
            if ($sth->err)
            {
                $@ = $sth->errstr . " [$sql]";
            }
            else
            {
                $@ = "";
            }
        }
    }
    return @result;
}

=pod

=item Arrays($sql)

A generic query routine. Given an SQL statement, returns a list of
hashrefs, one per returned record, containing the values of each
record.

The example in the middle of page 50 of DuBois's I<MySQL> would return
a value similar to:

 my @arrayrefs = (
  [ 'Tyler',     'John',     '1790-03-29' ],
  [ 'Buchanan',  'James',    '1791-04-23' ],
  [ 'Polk',      'James K',  '1795-11-02' ],
  [ 'Fillmore',  'Millard',  '1800-01-07' ],
  [ 'Pierce',    'Franklin', '1804-11-23' ],
 );

On error, C<$@> has the error text, and false is returned. If the
query doesn't return a record, false is returned, but C<$@> is also
false.

=cut

sub Arrays($$@)
{
    my $self      = shift;
    my $sql       = shift;
    my @bind_vals = @_;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected Arrays()";
        return ();
    }

    print "ARRAYS: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};

        while (my $ref = $sth->fetchrow_arrayref)
        {
            push @records, [@{$ref}]; ## perldoc DBI to see why!
        }
    }
    return @records;
}

=pod

=item FlatArray($sql)

A generic query routine. Pass an SQL string, and all matching fields
of all matching records are returned in one big list.

If the query matches a single records, C<FlatArray()> ends up being
the same as C<Array()>. But if there are multiple records matched, the
return list will contain a set of fields from each record.

The example in the middle of page 50 of DuBois's I<MySQL> would return
a value similar to:

     my @items = (
         'Tyler', 'John', '1790-03-29', 'Buchanan', 'James', '1791-04-23',
         'Polk', 'James K', '1795-11-02', 'Fillmore', 'Millard',
         '1800-01-07', 'Pierce', 'Franklin', '1804-11-23'
     );

C<FlatArray()> tends to be most useful when the query returns one
column per record, as with

    my @names = $db->FlatArray('select distinct name from mydb');

or two records with a key/value relationship:

    my %IdToName = $db->FlatArray('select id, name from mydb');

But you never know.

=cut

sub FlatArray($$@)
{
    my $self      = shift;
    my $sql       = shift;
    my @bind_vals = @_;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected in FlatArray()";
        return ();
    }

    print "FLATARRAY: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};

        while (my $ref = $sth->fetchrow_arrayref)
        {
            push @records, @{$ref};
        }
    }
    return @records;
}

=pod

=item Scalar($sql)

A generic query routine. Pass an SQL string, and a scalar will be
returned to you.

If the query matches a single row column pair this is what you want.
C<Scalar()> is useful for computational queries, count(*), max(xxx),
etc.

my $max = $dbh->Scalar('select max(id) from personnel');

If the result set would have been an array, scalar return the first
item on the first row and print a warning.

=cut

sub Scalar()
{
    my $self = shift;
    my $sql  = shift;
    my @bind_vals = @_;
    my $ret;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected in Scalar()";
        return ();
    }

    print STDERR "SCALAR: $sql\n" if $self->{VERBOSE};

    if ($self->Execute($sql, @bind_vals))
    {
        my $sth = $self->{RecentExecutedSth};

        if ($sth->rows() > 1 or $sth->{NUM_OF_FIELDS} > 1)
        {
	  warn "$sql in DWIW::Scalar returned more than 1 row and/or column";
        }
	my $ref = $sth->fetchrow_arrayref;
	$ret = ${$ref}[0];
    }
    return $ret;
}

=pod

=item CSV($sql)

A generic query routine. Pass an SQL string, and a CSV scalar will be
returned to you.

my $max = $dbh->CSV('select * from personnel');

The example in the middle of page 50 of DuBois\'s I<MySQL> would
return a value similar to:

     my $item = '"Tyler","John","1790-03-29"\n
                 "Buchanan","James","1791-04-23"\n
                 "Polk","James K","1795-11-02"\n
                 "Fillmore","Millard","1800-01-07",\n
                 "Pierce","Franklin","1804-11-23"\n';

=cut

sub CSV()
{
    my $self = shift;
    my $sql  = shift;
    my $ret;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected in Scalar()";
        return ();
    }

    print STDERR "SCALAR: $sql\n" if $self->{VERBOSE};

    if ($self->Execute($sql))
    {
        my $sth = $self->{RecentExecutedSth};

        while (my $ref = $sth->fetchrow_arrayref)
        {
            my $col = 0;
            foreach (@{$ref})
            {
	        if (defined($_)) {
		  $ret .= ($sth->{mysql_type_name}[$col++] =~
			   /(char|text|binary|blob)/) ?
			     "\"$_\"," : "$_,";
		} else {
		  $ret .= "NULL,";
		}
	    }
	    $ret =~ s/,$/\n/;
        }
    }
    return $ret;
}

=pod

=item Verbose([boolean])

Returns the value of the verbose flag associated with the connection.
If a value is provided, it is taken as the new value to install.
Verbose is OFF by default.  If you pass a true value, you'll get some
verbose output each time a query executes.

Returns the current value.

=cut

sub Verbose()
{
    my $self = shift;
    my $val = $self->{VERBOSE};

    if (@_)
    {
        $self->{VERBOSE} = shift;
    }

    return $val;
}

=pod

=item Quiet()

When errors occur, a message will be sent to STDOUT if Quiet is true
(it is by default).  Pass a false value to disble it.

Returns the current value.

=cut

sub Quiet()
{
    my $self = shift;

    if (@_)
    {
        $self->{QUIET} = shift;
    }

    return $self->{QUIET};
}

=pod

=item Safe()

Enable or disable "safe" mode (on by default).  In "safe" mode, you
must prefix a native DBI method call with "dbi_" in order to call it.
If safe mode is off, you can call native DBI mathods using their real
names.

For example, in safe mode, you'd write something like this:

  $db->dbi_commit;

but in unsafe mode you could use:

  $db->commit;

The rationale behind having a safe mode is that you probably don't
want to mix DBIx::DWIW and DBI method calls on an object unless you
know what you're doing.  You need to opt-in.

C<Safe()> returns the current value.

=cut

sub Safe($;$)
{
    my $self = shift;

    if (@_)
    {
        $self->{SAFE} = shift;
    }

    return $self->{SAFE};
}

=pod

=item dbh()

Returns the real DBI database handle for the connection.

=cut

sub dbh($)
{
    my $self = shift;
    return $self->{DBH};
}

=pod

=item RetryWait($error)

This method is called each time there is a error (usually caused by a
network outage or a server going down) which a sub-class may want to
examine and decide how to continue.

If C<RetryWait()> returns 1, the operation which was being attempted
when the failure occured will be retried.  If it returns 0, the action
will fail.

The default implementation causes your application to emit a message
to STDOUT (via a C<warn()> call) and then sleep for 30 seconds before
retrying.  You probably want to override this so that it will
eventually give up.  Otherwise your application may hang forever.  It
does maintain a count of how many times the retry has been attempted
in C<$self->{RetryCount}>.

=cut

sub RetryWait($$)
{
    my $self  = shift;
    my $error = shift;

    if (not $self->{RetryStart})
    {
        $self->{RetryStart} = time;
        $self->{RetryCommand} = $0;
        $0 = "(waiting on db) $0";
    }

    warn "db connection down ($error), retry in 30 seconds" unless $self->{QUIET};

    $self->{RetryCount}++;

    sleep 30;
    return 1;
}

##
## [non-public member function]
##
## Called whenever a database operation has been successful, to reset the
## internal counters, and to send a "back up" message, if appropriate.
##
sub _OperationSuccessful($)
{
    my $self = shift;

    if ($self->{RetryCount} and $self->{RetryCount} > 1)
    {
        my $now   = localtime;
        my $since = localtime($self->{RetryStart});

        $0 = $self->{RetryCommand} if $self->{RetryCommand};

        warn "$now: $self->{DESC} is back up (down sice $since)\n" unless $self->{QUIET};
    }

    $self->{RetryCount}  = 0;
    $self->{RetryStart}  = undef;
    $self->{RetryCommand}= undef;
}

##
## [non-public member function]
##
## Called whenever a database operation has finally failed after all the
## retries that will be done for it.
##
sub _OperationFailed($)
{
    my $self = shift;
    $0 = $self->{RetryCommand} if $self->{RetryCommand};

    $self->{RetryCount}  = 0;
    $self->{RetryStart}  = undef;
    $self->{RetryCommand}= undef;
}

=pod

=back

=head1 Local Configuration

There are two ways to to configure C<DBIx::DWIW> for your local
databases.  The simplest (but least flexible) way is to create a
package like:

    package MyDBI;
    @ISA = 'DBIx::DWIW';
    use strict;

    sub DefaultDB   { "MyDatabase"         }
    sub DefaultUser { "defaultuser"        }
    sub DefaultPass { "paSSw0rd"           }
    sub DefaultHost { "mysql.somehost.com" }
    sub DefaultPort { 3306                 }

The four routines override those in C<DBIx::DWIW>, and explicitly
provide exactly what's needed to contact the given database.

The user can then use

    use MyDBI
    my $db = MyDBI->Connect();

and not have to worry about the details.

A more flexible approach appropriate for multiple-database or
multiple-user installations is to create a more complex package, such
as the C<MyDBI.pm> which was included in the C<examples> sub-directory
of the DBIx::DWIW distribution.

In that setup, you have quit a bit of control over what connection
parameters are used.  And, since it's Just Perl Code, you can do
anything you need in there.

=head2 Methods Related to Connection Defaults

The following methods are provided to support this in sub-classes:

=over

=item LocalConfig($name)

Passed a configuration name, C<LocalConfig()> should return a list of
connection parameters suitable for passing to C<Connect()>.

By default, C<LocalConfig()> simply returns undef.

=cut

sub LocalConfig($$)
{
    return undef;
}

=pod

=item DefaultDB($config_name)

Returns the default database name for the given configuration.  Calls
C<LocalConfig()> to get it.

=cut

sub DefaultDB($)
{
    my ($class, $DB) = @_;

    if (my $DbConfig = $class->LocalConfig($DB))
    {
        return $DbConfig->{DB};
    }

    return undef;
}

=pod

=item DefaultUser($config_name)

Returns the default username for the given configuration. Calls
C<LocalConfig()> to get it.

=cut

sub DefaultUser($$)
{
    my ($class, $DB) = @_;

    if (my $DbConfig = $class->LocalConfig($DB))
    {
        return $DbConfig->{User};
    }
    return undef;
}

=pod

=item DefaultPass($config_name)

Returns the default password for the given configuration. Calls
C<LocalConfig()> to get it.

=cut

sub DefaultPass($$$)
{
    my ($class, $DB, $User) = @_;
    if (my $DbConfig = $class->LocalConfig($DB))
    {
        if ($DbConfig->{Pass})
        {
            return $DbConfig->{Pass};
        }
    }
    return undef;
}

=pod

=item DefaultHost($config_name)

Returns the default hostname for the given configuration.  Calls
C<LocalConfig()> to get it.

=cut

sub DefaultHost($$)
{
    my ($class, $DB) = @_;
    if (my $DbConfig = $class->LocalConfig($DB))
    {
        if ($DbConfig->{Host})
        {
                return $DbConfig->{Host};
        }
    }
    return undef;
}

=pod

=item DefaultPort($config_name)

Returns the default Port number for the given configuration.  Calls
C<LocalConfig()> to get it.

=cut

sub DefaultPort($$)
{
    my ($class, $DB) = @_;
    if (my $DbConfig = $class->LocalConfig($DB))
    {
        if ($DbConfig->{Port})
        {
            if ($DbConfig->{Host} eq hostname)
            {
                return undef; #use local connection
            }
            else
            {
                return $DbConfig->{Host};
            }
        }
    }
    return undef;
}

######################################################################

=pod

=back

=head1 The DBIx::DWIW::Statement CLASS

Calling C<Prepre()> on a database handle returns a
DBIx::DWIW::Statement object which acts like a limited DBI statement
handle.

=head2 Methods

The following methods can be called on a statement object.

=over

=cut

package DBIx::DWIW::Statement;

use vars '$AUTOLOAD';

sub AUTOLOAD
{
    my $self   = shift;
    my $method = $AUTOLOAD;

    $method =~ s/.*:://;  ## strip the package name

    my $orig_method = $method;

    if ($self->{SAFE})
    {
        if (not $method =~ s/^dbi_//)
        {
            Carp::cluck("undefined or unsafe method ($orig_method) called in");
        }
    }

    if ($self->{DBI_STH} and $self->{DBI_STH}->can($method))
    {
        $self->{DBI_STH}->$method(@_);
    }
    else
    {
        Carp::cluck("undefined method ($orig_method) called");
    }
}

## This looks funny, so I should probably explain what is going on.
## When Execute() is called on a statement handle, we need to know
## which $db object to use for execution.  Luckily that was stashed
## away in $self->{PARENT} when the statement was created.  So we call
## the _Execute method on our parent $db object and pass ourselves.
## Sice $db->_Execute() only accepts Statement objects, this is just
## as it should be.

=pod

=item Execute([@values])

Executes the statement.  If values are provided, they'll be substituted
for the appropriate placeholders in the SQL.

=cut

sub Execute(@)
{
    my $self      = shift;
    my @bind_vals = @_;
    my $db        = $self->{PARENT};

    return $db->_Execute($self, @bind_vals);
}

sub DESTROY
{
#      my $self = shift;

#      return unless defined $self;
#      return unless ref($self);

#      if ($self->{DBI_STH})
#      {
#          $self->{DBI_STH}->finish();
#      }
}

1;

=pod

=back

=head1 AUTHORS

DBIx::DWIW evolved out of some Perl modules that we developed and used
in Yahoo! Finance (http://finance.yahoo.com).  The folowing people
contributed to its development:

  Jeffrey Friedl (jfriedl@yahoo.com)
  rayg (rayg@bitbaron.com)
  John Hagelgans (jhagel@yahoo-inc.com)
  David Yan (davidyan@yahoo-inc.com)
  Jeremy Zawodny (Jeremy@Zawodny.com)

=head1 CREDITS

The following folks have provded feedback, patches, and other help
along the way:

  Eric E. Bowles (bowles@ambisys.com)

Please direct comments, questions, etc to Jeremy for the time being.
Thanks.

=head1 COPYRIGHT

DBIx::DWIW is Copyright (c) 2001, Yahoo! Inc.  All rights reserved.

You may distribute under the same terms of the Artistic License, as
specified in the Perl README file.

=head1 SEE ALSO

L<DBI>, L<perl>

Jeremy's presentation at the 2001 Open Source Database Summit, which
introduced DBIx::DWIW is availble from:

  http://jeremy.zawodny.com/mysql/

=cut
