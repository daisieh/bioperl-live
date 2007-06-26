# $Id$
#
# BioPerl module for Bio::DB::EUtilParameters
#
# Cared for by Chris Fields <cjfields at uiuc dot edu>
#
# Copyright Chris Fields
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=head1 NAME

Bio::DB::EUtilParameters - Manipulation of NCBI eutil-based parameters for
remote database requests.

=head1 SYNOPSIS

 # Bio::DB::EUtilParameters implements Bio::ParameterBaseI
 
 my @params = (-eutil => 'efetch',
              db => 'nucleotide',
              id => \@ids,
              email => 'me@foo.bar',
              retmode => 'xml');
 
 my $p = Bio::DB::EUtilParameters->new(@params);
 
 if ($p->parameters_changed) {...} # state information
 
 $p->set_parameters(@extra_params); # set new NCBI parameters, leaves others preset
 
 $p->reset_parameters(@new_params); # reset NCBI parameters to original state
 
 $p->to_string(); # get a URI-encoded string representation of the URL address
 
 $p->to_request(); # get an HTTP::Request object (to pass on to LWP::UserAgent)
 
=head1 DESCRIPTION

Bio::DB::EUtilParameters is-a Bio::ParameterBaseI implementation that allows
simple manipulation of NCBI eutil parameters for CGI-based queries. SOAP-based
methods may be added in the future.

For simplicity parameters do not require dashes when passed and do not need URI
encoding (spaces are converted to '+', symbols encoded, etc). Also, the
following extra parameters can be passed to the new() constructor or via
set_parameters() or reset_parameters():

  eutil - the eutil to be used. The default is 'efetch' if not set.
  correspondence - Flag for how IDs are treated. Default is undef (none).
  history - a Bio::Tools::EUtilities::HistoryI object. Default is undef (none).

At this point minimal checking is done for potential errors in parameter
passing, though these should be easily added in the future when necessary.

=head1 TODO

Possibly integrate SOAP-compliant methods. SOAP::Lite may be undergoing an
complete rewrite so I'm hesitant about adding this in immediately.

=head1 FEEDBACK

=head2 Mailing Lists

User feedback is an integral part of the 
evolution of this and other Bioperl modules. Send
your comments and suggestions preferably to one
of the Bioperl mailing lists. Your participation
is much appreciated.

  bioperl-l@lists.open-bio.org               - General discussion
  http://www.bioperl.org/wiki/Mailing_lists  - About the mailing lists

=head2 Reporting Bugs

Report bugs to the Bioperl bug tracking system to
help us keep track the bugs and their resolution.
Bug reports can be submitted via the web.

  http://bugzilla.open-bio.org/

=head1 AUTHOR 

Email cjfields at uiuc dot edu

=head1 APPENDIX

The rest of the documentation details each of the
object methods. Internal methods are usually
preceded with a _

=cut

# Let the code begin...

package Bio::DB::EUtilParameters;
use strict;
use warnings;

use base qw(Bio::Root::Root Bio::ParameterBaseI);
use URI;
use HTTP::Request;

# eutils only has one hostbase URL

# mode : GET or POST (HTTP::Request)
# location : CGI location
# params : allowed parameters for that eutil
my %MODE = (
    'einfo'     => {
        'mode'     => 'GET',
        'location' => 'einfo.fcgi',
        'params'   => [qw(db retmode tool email)],
                   },
    'epost'     => {
        'mode'     => 'POST',
        'location' => 'epost.fcgi',
        'params'   => [qw(db retmode id tool email)],
                   },
    'efetch'    => {
        'mode'     => 'GET',
        'location' => 'efetch.fcgi',
        'params'   => [qw(db retmode id retmax retstart rettype strand seq_start
                       seq_stop complexity report tool email)],
                   },
    'esearch'   => {
        'mode'     => 'GET',
        'location' => 'esearch.fcgi',
        'params'   => [qw(db retmode usehistory term field reldate mindate
                       maxdate datetype retmax retstart rettype sort tool email WebEnv query_key)],
                   },
    'esummary'  => {
        'mode'     => 'GET',
        'location' => 'esummary.fcgi',
        'params'   => [qw(db retmode id retmax retstart rettype tool email )],
                   },
    'elink'     => {
        'mode'     => 'GET',
        'location' => 'elink.fcgi',
        'params'   => [qw(db retmode id reldate mindate maxdate datetype term 
                    dbfrom holding cmd version tool email)],
                   },
    'egquery'   => {
        'mode'     => 'GET',
        'location' => 'egquery.fcgi',
        'params'   => [qw(term retmode tool email)],
                   },
    'espell'    => {
        'mode'     => 'GET',
        'location' => 'espell.fcgi',
        'params'   => [qw(db retmode term tool email )],
                   }
);

# used only if history is present
my @HISTORY_PARAMS = qw(db sort seq_start seq_stop strand complexity rettype
    retstart retmax cmd linkname retmode WebEnv query_key);            

my @PARAMS;

# generate getter/setters (will move this into individual ones at some point)

BEGIN {
    @PARAMS = qw(db id email retmode rettype usehistory term field tool
    reldate mindate maxdate datetype retstart retmax sort seq_start seq_stop
    strand complexity report dbfrom cmd holding version linkname WebEnv
    query_key);
    for my $method (@PARAMS) {
        eval <<END;
sub $method {
    my (\$self, \$val) = \@_;
    if (defined \$val) {
        \$self->{'_statechange'} = 1 if (!defined \$self->{'_$method'}) ||
            (defined \$self->{'_$method'} && \$self->{'_$method'} ne \$val);
        \$self->{'_$method'} = \$val;
    }
    return \$self->{'_$method'};
}
END
    }
}

sub new {
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(@args);
    my ($retmode) = $self->_rearrange(["RETMODE"],@args);
    $self->_set_from_args(\@args,
        -methods => [@PARAMS, qw(eutil history correspondence)]);
    $self->eutil() || $self->eutil('efetch');
    # set default retmode if not explicitly set    
    $self->set_default_retmode if (!$retmode);
    $self->{'_statechange'} = 1;
    return $self;
}

=head1 Bio::ParameterBaseI implemented methods

=head2 set_parameters

 Title   : set_parameters
 Usage   : $pobj->set_parameters(@params);
 Function: sets the NCBI parameters listed in the hash or array
 Returns : None
 Args    : [optional] hash or array of parameter/values.  
 Note    : This sets any parameter (i.e. doesn't screen them using $MODE or via
           set history).

=cut

sub set_parameters {
    my ($self, @args) = @_;
    # allow automated resetting; must check to ensure that retmode isn't explicitly passed
    my $newmode = $self->_rearrange(["RETMODE"],@args);
    $self->_set_from_args(\@args, -methods => [@PARAMS, qw(eutil correspondence history)]);
    # set default retmode if not explicitly passed
    $self->set_default_retmode unless $newmode;
}

=head2 reset_parameters

 Title   : reset_parameters
 Usage   : resets values
 Function: resets parameters to either undef or value in passed hash
 Returns : none
 Args    : [optional] hash of parameter-value pairs
 Note    : this also resets eutil(), correspondence(), and the history and request
           cache

=cut

sub reset_parameters {
    my ($self, @args) = @_;
    # is there a better way of doing this?  probably, but this works...
    my ($retmode) = $self->_rearrange(["RETMODE"],@args);
    map { defined $self->{"_$_"} && undef $self->{"_$_"} } (@PARAMS, qw(eutil correspondence history_cache request_cache));
    $self->_set_from_args(\@args, -methods => [@PARAMS, qw(eutil correspondence history)]);
    $self->eutil() || $self->eutil('efetch');
    $self->set_default_retmode unless $retmode;
    $self->{'_statechange'} = 1;
}

=head2 parameters_changed

 Title   : parameters_changed
 Usage   : if ($pobj->parameters_changed) {...}
 Function: Returns TRUE if parameters have changed
 Returns : Boolean (0 or 1)
 Args    : [optional] Boolean

=cut

sub parameters_changed {
    my ($self) = @_;
    $self->{'_statechange'};
}

=head2 available_parameters

 Title   : available_parameters
 Usage   : @params = $pobj->available_parameters()
 Function: Returns a list of the available parameters
 Returns : Array of available parameters (no values)
 Args    : [optional] A string; either eutil name (for returning eutil-specific
           parameters) or 'history' (for those parameters allowed when retrieving
           data stored on the remote server using a 'Cookie').  

=cut

sub available_parameters {
    my ($self, $type) = @_;
    $type ||= 'all';
    if ($type eq 'all') {
        return @PARAMS;
    } elsif ($type eq 'history') {
        return @HISTORY_PARAMS;
    } else {
        $self->throw("$type parameters not supported") if !exists $MODE{$type};
        return @{$MODE{$type}->{params}};
    }
}

=head2 get_parameters

 Title   : get_parameters
 Usage   : @params = $pobj->get_parameters;
           %params = $pobj->get_parameters;
 Function: Returns list of key/value pairs, parameter => value
 Returns : Flattened list of key-value pairs. All key-value pairs returned,
           though subsets can be returned based on the '-type' parameter.  
           Data passed as an array ref are returned based on whether the
           '-join_id' flag is set (default is the same array ref). 
 Args    : -type : the eutil name or 'history', for returning a subset of
                parameters (Default: returns all)
           -join_ids : Boolean; join IDs based on correspondence (Default: no join)

=cut

sub get_parameters {
    my ($self, @args) = @_;
    my ($type, $join) = $self->_rearrange([qw(TYPE JOIN_IDS)], @args);
    $type ||= '';
    my @final = $self->available_parameters($type);
    my @p;
    for my $param (@final) {
        if ($param eq 'id' && $self->id && $join) {
            if ($self->correspondence && $self->eutil eq 'elink') {
                for my $id_group (@{ $self->id }) {
                    if (ref($id_group) eq 'ARRAY') {
                        push @p, ('id' => join(q(,), @{ $id_group }));
                    }
                    elsif (!ref($id_group)) {
                        push @p, ('id'  => $id_group);
                    }
                    else {
                        $self->throw("Unknown ID type: $id_group");
                    }
                }
            } else {
                push @p, ($param => join(',', @{ $self->id }));
            }
        }
        elsif ($param eq 'db' && $self->db) {
            my $db = $self->db;
            (ref $db eq 'ARRAY') ? 
                push @p, ($param => join(',', @{ $db })) :
                push @p, ($param => $db) ;
        }
        else {
            push @p, ($param => $self->{"_$param"}) if defined $self->{"_$param"};
        }
    }
    return @p;
}

=head1 Implementation-specific to-* methods

=head2 to_string

 Title   : to_string
 Usage   : $string = $pobj->to_string;
 Function: Returns string (URL only in this case)
 Returns : String (URL only for now)
 Args    : [optional] 'all'; build URI::http using all parameters
           Default : Builds based on allowed parameters (presence of history data
           or eutil type in %MODE).
 Note    : Changes state of object.  Absolute string

=cut

sub to_string {
    my ($self, @args) = @_;
    # calling to_uri changes the state
    if ($self->parameters_changed || !defined $self->{'_string_cache'}) {
        my $string = $self->to_request(@args)->uri->as_string;
        $self->{'_statechange'} = 0;
        $self->{'_string_cache'} = $string;
    }
    return $self->{'_string_cache'};
}

=head2 to_request

 Title   : to_request
 Usage   : $uri = $pobj->to_request;
 Function: Returns HTTP::Request object
 Returns : HTTP::Request
 Args    : [optional] 'all'; builds request using all parameters
           Default : Builds based on allowed parameters (presence of history data
           or eutil type in %MODE).
 Note    : Changes state of object (to boolean FALSE).  Used for CGI-based GET/POST
 
=cut

sub to_request {
    my ($self, $type) = @_;
    if ($self->parameters_changed || !defined $self->{'_request_cache'}) {
        my $eutil = $self->eutil;
        $self->throw("No eutil set") if !$eutil;
        #set default retmode
        my $history = ($self->history) ? 1 : 0;
        $type ||= ($history) ? 'history' : $eutil;
        my ($location, $mode) = ($MODE{$eutil}->{location}, $MODE{$eutil}->{mode});
        my $request;
        my $uri = URI->new($self->url_base_address . $location);
        if ($mode eq 'GET') {
            $uri->query_form($self->get_parameters(-type => $type, -join_ids => 1) );
            $request = HTTP::Request->new($mode => $uri);
            $self->{'_request_cache'} = $request;
        } elsif ($mode eq 'POST') {
            $request = HTTP::Request->new($mode => $uri->as_string);
            $uri->query_form($self->get_parameters(-type => $type, -join_ids => 1) );
            $request->content_type('application/x-www-form-urlencoded');
            $request->content($uri->query);
            $self->{'_request_cache'} = $request;
        } else {
            $self->throw("Unrecognized request mode: $mode");
        }
        $self->{'_statechange'} = 0;
        $self->{'_request_cache'} = $request;
    }
    return $self->{'_request_cache'};
}

=head1 Implementation specific-methods

=head2 eutil

 Title   : eutil
 Usage   : $p->eutil('efetch')
 Function: gets/sets the eutil for this set of parameters
 Returns : string (eutil)
 Args    : [optional] string (eutil)
 Throws  : '$eutil not supported' if eutil not present
 Note    : This does not reset retmode to the default if called directly.
 
=cut

sub eutil {
    my ($self, $eutil) = @_;
    if ($eutil) {
        $self->throw("$eutil not supported") if !exists $MODE{$eutil};
        $self->{'_eutil'} = $eutil;
        $self->{'_statechange'} = 1;
    }
    return $self->{'_eutil'};
}

=head2 history

 Title   : history
 Usage   : $p->history($history);
 Function: gets/sets the history object to be used for these parameters
 Returns : Bio::Tools::EUtilities::HistoryI (if set)
 Args    : [optional] Bio::Tools::EUtilities::HistoryI 
 Throws  : Passed something other than a Bio::Tools::EUtilities::HistoryI 
 Note    : This overrides WebEnv() and query_key() settings when set

=cut

sub history {
    my ($self, $history) = @_;
    if ($history) {
        $self->throw('Not a Bio::Tools::EUtilities::HistoryI object!') if
            !$history->isa('Bio::Tools::EUtilities::HistoryI');
        $self->throw('No history present in HistoryI object') if
            !$history->has_history;
        my ($webenv, $qkey) = $history->history;
        $self->WebEnv($webenv);
        $self->query_key($qkey);
        $self->{'_statechange'} = 1;
        $self->{'_history_cache'} = $history;
    }
    return $self->{'_history_cache'};
}

=head2 correspondence

 Title   : correspondence
 Usage   : $p->correspondence(1);
 Function: Sets flag for posting IDs for one-to-one correspondence
 Returns : Boolean
 Args    : [optional] boolean value

=cut

sub correspondence {
    my ($self, $corr) = @_;
    if (defined $corr) {
        $self->{'_correspondence'} = $corr;
        $self->{'_statechange'} = 1;
    }
    return $self->{'_correspondence'};
}

=head2 url_base_address

 Title   : url_base_address
 Usage   : $address = $p->url_base_address();
 Function: Get URL base address
 Returns : String
 Args    : None in this implementation; the URL is fixed

=cut

{
    my $HOSTBASE = 'http://eutils.ncbi.nlm.nih.gov/entrez/eutils/';
    
    sub url_base_address {
        my ($self, $address) = @_;
        return $HOSTBASE;
    }
}

=head2 set_default_retmode

 Title   : set_default_retmode
 Usage   : $p->set_default_retmode();
 Function: sets retmode to default value specified by the eutil() and the value
           in %NCBI_DATABASE (for efetch only) if called
 Returns : none
 Args    : none

=cut

{
    # default retmode if one is not supplied
    my %NCBI_DATABASE = (
        'pubmed'           => 'xml',
        'protein'          => 'text',
        'nucleotide'       => 'text',
        'nuccore'          => 'text',
        'nucgss'           => 'text',
        'nucest'           => 'text',
        'structure'        => 'text',
        'genome'           => 'text',
        'books'            => 'xml',
        'cancerchromosomes'=> 'xml',
        'cdd'              => 'xml',
        'domains'          => 'xml',
        'gene'             => 'asn1',
        'genomeprj'        => 'xml',
        'gensat'           => 'xml',
        'geo'              => 'xml',
        'gds'              => 'xml',
        'homologene'       => 'xml',
        'journals'         => 'text',
        'mesh'             => 'xml',
        'ncbisearch'       => 'xml',
        'nlmcatalog'       => 'xml',
        'omia'             => 'xml',
        'omim'             => 'xml',
        'pmc'              => 'xml',
        'popset'           => 'xml',
        'probe'            => 'xml',
        'pcassay'          => 'xml',
        'pccompound'       => 'xml',
        'pcsubstance'      => 'xml',
        'snp'              => 'xml',
        'taxonomy'         => 'xml',
        'unigene'          => 'xml',
        'unists'           => 'xml',
    );

    sub set_default_retmode {
        my $self = shift;
        if ($self->eutil eq 'efetch') {
            my $db = $self->db || return; # assume retmode will be set along with db
            $self->throw('Database $db not recognized')
                 if !exists $NCBI_DATABASE{$db};
            # set efetch-based retmode
            $self->retmode($NCBI_DATABASE{$db});
        } else {
            $self->retmode('xml');
        }
    }
}

1;

