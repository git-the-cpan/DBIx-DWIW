## $Source: /CVSROOT/yahoo/finance/lib/perl/PackageMasters/DBIx-DWIW/DWIW.pm,v $
##
## $Id: DWIW.pm,v 1.13 2001/10/14 21:53:14 jzawodn Exp $

package DBIx::DWIW;

use 5.005;
use strict;
use vars qw[$VERSION $SAFE];

$VERSION = '0.07';
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
way to do most things.  If you want to run a query and get the reults
back as a list of hashrefs, there's one way to do that.  The API may
sacrifice speed in some cases, but new users can easily lean the
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

=over

=cut

use DBI;
use Carp;
use Sys::Hostname;

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
            warn "unknown use arguement: $arg";
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

=back

There are a minimum of four components to any database connection: DB,
User, Pass, and Host. If any are not provided, there may be defaults
that kick in. A local configuration package, such as the C<MyDBI>
example class that comes with DBIx::DWIW, may provide appropriate
default connection values for several database. In such a case, a
client my be able to simply use:

    my $db = MyDBI->Conenct(DB => 'Finances');

to connect to the C<Finances> database.

as a convenience, you can just give the database name:

    my $db = MyDBI->Conenct('Finances');

See the local configuration package appropriate to your installation
for more information about what is and isn't preconfigured.

=cut

sub Connect($@)
{
    my $class = shift;

    ##
    ## If the user asks for a slave connection like this:
    ##
    ##   Connect('Slave', 'ConfigName')
    ##
    ## We'll try caling FindSlave() to find a slave server.
    ##
    if (@_ == 2 and ($_[0] eq 'Slave' or $_[0] eq 'ReadOnly'))
    {
        if ($class->can('FindSlave'))
        {
            @_ = $class->FindSlave($_[1]);
        }
    }

    ##
    ## Handle $self->Connect('SomeConfig')
    ##
    if (@_ == 1 and $class->LocalConfig($_[0]))
    {
        @_ = %{$class->LocalConfig($_[0])};
    }

    ##
    ## Expecting hash-style arguments.
    ##
    if (@_ % 2)
    {
        die "bad number of arguments to Connect";
    }

    my %Options = @_;

    ##
    ## Fetch the arguments.
    ## Allow 'Db' for 'DB'.
    ##
    my $DB       =  delete($Options{DB})   || $class->DefaultDB();
    my $User     =  delete($Options{User}) || $class->DefaultUser($DB);
    my $Password =  delete($Options{Pass}) || $class->DefaultPass($DB, $User);
    my $Unique   =  delete($Options{Unique});
    my $Retry    = !delete($Options{NoRetry});
    my $Quiet    =  delete($Options{Quiet});
    my $NoAbort  =  delete($Options{NoAbort});
    my $Verbose  =  delete($Options{Verbose}); # undef = no change
                                               # true  = on
                                               # true  = off

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

    if (%Options)
    {
        my $keys = join(', ', keys %Options);
        $@ = "bad parameters [$keys] to Connect()";
        die $@ unless $NoAbort;
        return ();
    }

    my $myhost = hostname();
    my $desc;

    if (defined $Host)
    {
        $desc = "connection to $Host\'s MySql server from $myhost";
    }
    else
    {
        $desc = "local connection to MySql server on $myhost";
    }

    ##
    ## If we're not looking for a unique connection, and we already have
    ## one with the same options, use it.
    ##
    if (not $Unique)
    {
        if (my $db = $CurrentConnections{$Host,$User,$Password,$DB}) {

            if (defined $Verbose)
            {
                $db->{VERBOSE} = 1;
            }

            return $db;
        }
    }

    my $db = {
              DB         => $DB,
              DBH        => undef,
              DESC       => $desc,
              HOST       => $Host,
              PASS       => $Password,
              QUIET      => $Quiet,
              RETRY      => $Retry,
              UNIQUE     => $Unique,
              USER       => $User,
              VERBOSE    => $Verbose,
              SAFE       => $SAFE,
              RetryCount => 0,
             };

    $db = bless $db, $class;

  RETRY:
    my $dbh = DBI->connect("DBI:mysql:$DB:$Host;mysql_client_found_rows=1",
                           $User, $Password, { PrintError => 0 });

    if (not ref $dbh)
    {
        if ($Retry
            and
            $DBI::errstr =~ m/can\'t connect/i
            and
            $db->RetryWait($DBI::errstr))
        {
            goto RETRY;
        }

        warn "$DBI::errstr" if not $Quiet;
        $@ = "can't connect to database: $DBI::errstr";
        die $@ unless $NoAbort;
        $db->_OperationFailed();
        return ();
    }

    ##
    ## We got through....
    ##
    $db->_OperationSuccessful();
    $db->{DBH} = $dbh;

    ##
    ## Save this one if it's not to be unique.
    ##
    $CurrentConnections{$Host,$User,$Password,$DB} = $db if not $Unique;
    return $db;
}

*new = *Connect;

=item Disconnect()

Closes the connection. Upon program exit, this is called automatically
on all open connections. Returns true if the open connection was
closed, false if there was no connection, or there was some other
error (with the error being returned in C<$@>).

=cut

sub Disconnect($)
{
    my $db = shift;

    if (not $db->{UNIQUE})
    {
        delete $CurrentConnections{$db->{HOST},$db->{USER},$db->{PASS},$db->{DB}};
    }

    if (not $db->{DBH})
    {
        $@ = "not connected";
        return ();
    }
    elsif (not $db->{DBH}->disconnect())
    {
        $@ = "couldn't disconnect (or wasn't disconnected)";
        $db->{DBH} = undef;
        return ();
    }
    else
    {
        $@ = "";
        $db->{DBH} = undef;
        return 1;
    }
}

sub DESTROY($)
{
    my $self = shift; # self
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
    my @values    = @_;

    if (not ref $statement)
    {
        $@ = "non-reference passed to _Execute()";
        warn "$@" unless $self->{QUIET};
        return ();
    }

    my $sth = $statement->{DBI_STH};

    print "_EXECUTE: $statement->{SQL}: ", join(" | ", @values), "\n" if $self->{VERBOSE};

    ##
    ## Execute the statement. Retry if requested.
    ##
  RETRY:
    local($SIG{PIPE}) = 'IGNORE';

    $self->{ExecuteReturnCode} = $sth->execute(@values);

    if (not defined $self->{ExecuteReturnCode})
    {
        ## Check to see if the error is one we should retry for
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
            goto RETRY;
        }

        ## Really an error -- spit it out if needed.
        $@ = "$err [in prepared statement]";
        Carp::cluck "execute of prepared statement returned undef [$err]" if $self->{VERBOSE};
        $self->_OperationFailed();
        return undef;
    };

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

sub Execute()
{
    my $self = shift;
    my $sql  = shift;

    if (not $self->{DBH})
    {
        $@ = "not connected";
        Carp::croak "not connected to the database" unless $self->{QUIET};
    }

    print "EXECUTE> $sql\n" if $self->{VERBOSE};

    my $sth = $self->Prepare($sql);

    return $sth->Execute();
}

##
## Do is a synonynm for Execute.
##
*Do = *Execute;

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
    my $self = shift; #self
    my $sql  = shift;

    if (not $self->{DBH})
    {
        $@ = "not connected";

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

*InsertID = *InsertedId;
*LastInsertID = *InsertedId;
*LastInsertId = *InsertedId;

=item RowsAffected()

Returns the number of rows affected for the most recently executed
statement.  This is valid only if it was for a non-SELECT. (For
SELECTs, count the return values). As per the DBI, the -1 is returned
if there was an error.

=cut

sub RowsAffected()
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

sub RecentSql
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

sub PreparedSql
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

=cut

sub Hash()
{
    my $self  = shift;
    my $sql   = shift;

    if (not $self->{DBH})
    {
        $@ = "not connected";
        return ();
    }

    print "HASH: $sql\n" if ($self->{VERBOSE});

    my $result = undef;

    if ($self->Execute($sql))
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

sub Hashes()
{
    my $self = shift;
    my $sql  = shift;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected";
        return ();
    }

    print "HASHES: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql))
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

sub Array($$;$@)
{
    my $self = shift;
    my $sql  = shift;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected";
        return ();
    }

    print "ARRAY: $sql\n" if $self->{VERBOSE};

    my @result;

    if ($self->Execute($sql))
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

sub Arrays()
{
    my $self = shift;
    my $sql  = shift;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected";
        return ();
    }

    print "ARRAYS: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql))
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

sub FlatArray()
{
    my $self = shift;
    my $sql  = shift;

    $@ = "";

    if (not $self->{DBH})
    {
        $@ = "not connected";
        return ();
    }

    print "FLATARRAY: $sql\n" if $self->{VERBOSE};

    my @records;

    if ($self->Execute($sql))
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

=item Verbose([boolean])

Returns the value of the verbose flag associated with the connection.
If a value is provided, it is taken as the new value to install.
Verbose is OFF by default.  If you pass a true value, you'll get some
verbose output each time a query executes.

Returns the current value.

=cut

sub Verbose()
{
    my $db = shift; # self
    my $val = $db->{VERBOSE};

    if (@_)
    {
        $db->{VERBOSE} = shift;
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
    my $self = shift; # self
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
retrying.  You probably wnat to override this so that it will
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

        warn "$now: $self->{DESC} is back up (down sice $since)\n";
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
    @ISA = 'DBIx::DWIWl';
    use strict;

    sub DefaultDB   { "MyDatabase"         }
    sub DefaultUser { "defaultuser"        }
    sub DefaultPass { "paSSw0rd"           }
    sub DefaultHost { "mysql.somehost.com" }

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

The following methods are provided to support this in sub-classes:

=head2 Methods Related to Connection Defaults

=pod

=item LocalConfig($name)

Passed a configuration name, C<LocalConfig()> should return a list of
conncetion parameters suitable for passing to C<Connect()>.

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

=item DefaultHost()

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

Executes the statement.  If values are provided, they'll be substitued
for the appropriate placeholders in the SQL.

=cut

sub Execute(@)
{
    my $self = shift;
    my @vals = @_;
    my $db   = $self->{PARENT};

    return $db->_Execute($self, @vals);
}

sub DESTROY
{
}

1;

=pod

=back

=head1 AUTHORS

DBIx::DWIW evolved out of some Perl modules that we developed and used
in Yahoo! Finance (http://finance.yahoo.com).  The folowing people
contributed to its development:

  Jeffrey Friedl (jfriedl@yahoo.com)
  Ray Goldberger (rayg@bitbaron.com)
  Jeremy Zawodny (Jeremy@Zawodny.com)

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
