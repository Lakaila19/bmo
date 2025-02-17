# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::BugMail;

use 5.10.1;
use strict;
use warnings;

use Bugzilla::Error;
use Bugzilla::User;
use Bugzilla::Constants;
use Bugzilla::Util;
use Bugzilla::Bug;
use Bugzilla::Comment;
use Bugzilla::Mailer;
use Bugzilla::Hook;

use Date::Parse;
use Date::Format;
use Scalar::Util qw(blessed);
use List::MoreUtils qw(uniq firstidx);
use Sys::Hostname;
use Storable qw(dclone);

use constant BIT_DIRECT   => 1;
use constant BIT_WATCHING => 2;

sub relationships {
  my $ref = RELATIONSHIPS;

  # Clone it so that we don't modify the constant;
  my %relationships = %$ref;
  Bugzilla::Hook::process('bugmail_relationships',
    {relationships => \%relationships});
  return %relationships;
}

# This is a bit of a hack, basically keeping the old system()
# cmd line interface. Should clean this up at some point.
#
# args: bug_id, and an optional hash ref which may have keys for:
# changer, owner, qa, reporter, cc
# Optional hash contains values of people which will be forced to those
# roles when the email is sent.
# All the names are email addresses, not userids
# values are scalars, except for cc, which is a list
sub Send {
  my ($id, $forced, $params) = @_;
  $params ||= {};

  my $dbh = Bugzilla->dbh;
  my $bug = new Bugzilla::Bug($id);

  my $start = $bug->lastdiffed;
  my $end   = $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');

  # Bugzilla::User objects of people in various roles. More than one person
  # can 'have' a role, if the person in that role has changed, or people are
  # watching.
  my @assignees = ($bug->assigned_to);
  my @qa_contacts = $bug->qa_contact || ();

  my @ccs = @{$bug->cc_users};

  # Include the people passed in as being in particular roles.
  # This can include people who used to hold those roles.
  # At this point, we don't care if there are duplicates in these arrays.
  my $changer = $forced->{'changer'};
  if ($forced->{'owner'}) {
    push(@assignees, Bugzilla::User->check($forced->{'owner'}));
  }

  if ($forced->{'qacontact'}) {
    push(@qa_contacts, Bugzilla::User->check($forced->{'qacontact'}));
  }

  if ($forced->{'cc'}) {
    foreach my $cc (@{$forced->{'cc'}}) {
      push(@ccs, Bugzilla::User->check($cc));
    }
  }
  my %user_cache = map { $_->id => $_ } (@assignees, @qa_contacts, @ccs);

  my @diffs;
  my @referenced_bugs;
  if (!$start) {
    @diffs = _get_new_bugmail_fields($bug);
  }

  if ($params->{dep_only}) {
    my $fields = Bugzilla->fields({by_name => 1});
    push(
      @diffs,
      {
        field_name => 'bug_status',
        field_desc => $fields->{bug_status}->description,
        old        => $params->{changes}->{bug_status}->[0],
        new        => $params->{changes}->{bug_status}->[1],
        login_name => $changer->login,
        blocker    => $params->{blocker}
      },
      {
        field_name => 'resolution',
        field_desc => $fields->{resolution}->description,
        old        => $params->{changes}->{resolution}->[0],
        new        => $params->{changes}->{resolution}->[1],
        login_name => $changer->login,
        blocker    => $params->{blocker}
      }
    );
    push(@referenced_bugs, $params->{blocker}->id);
  }
  else {
    my ($diffs, $referenced) = _get_diffs($bug, $end, \%user_cache);
    push(@diffs,           @$diffs);
    push(@referenced_bugs, @$referenced);
  }

  my $comments = $bug->comments({after => $start, to => $end});

  # Skip empty comments.
  @$comments = grep { $_->type || $_->body =~ /\S/ } @$comments;

  # Add duplicate bug to referenced bug list
  foreach my $comment (@$comments) {
    if ($comment->type == CMT_DUPE_OF || $comment->type == CMT_HAS_DUPE) {
      push(@referenced_bugs, $comment->extra_data);
    }
  }

  # Add dependencies and regressions to referenced bug list on new bugs
  if (!$start) {
    push(@referenced_bugs,
      map { @{$bug->$_} } qw(dependson blocked regressed_by regresses));
    push @referenced_bugs, _parse_see_also(map { $_->name } @{$bug->see_also});
  }

  # If no changes have been made, there is no need to process further.
  return {'sent' => []} unless scalar(@diffs) || scalar(@$comments);

  ###########################################################################
  # Start of email filtering code
  ###########################################################################

  # A user_id => roles hash to keep track of people.
  my %recipients;
  my %watching;

  # Now we work out all the people involved with this bug, and note all of
  # the relationships in a hash. The keys are userids, the values are an
  # array of role constants.

  # CCs
  $recipients{$_->id}->{+REL_CC} = BIT_DIRECT foreach (@ccs);

  # Reporter (there's only ever one)
  $recipients{$bug->reporter->id}->{+REL_REPORTER} = BIT_DIRECT;

  # QA Contact
  if (Bugzilla->params->{'useqacontact'}) {
    foreach (@qa_contacts) {

      # QA Contact can be blank; ignore it if so.
      $recipients{$_->id}->{+REL_QA} = BIT_DIRECT if $_;
    }
  }

  # Assignee
  $recipients{$_->id}->{+REL_ASSIGNEE} = BIT_DIRECT foreach (@assignees);

  # The last relevant set of people are those who are being removed from
  # their roles in this change. We get their names out of the diffs.
  foreach my $change (@diffs) {
    if ($change->{old}) {

      # You can't stop being the reporter, so we don't check that
      # relationship here.
      # Ignore people whose user account has been deleted or renamed.
      if ($change->{field_name} eq 'cc') {
        foreach my $cc_user (split(/[\s,]+/, $change->{old})) {
          my $uid = login_to_id($cc_user);
          $recipients{$uid}->{+REL_CC} = BIT_DIRECT if $uid;
        }
      }
      elsif ($change->{field_name} eq 'qa_contact') {
        my $uid = login_to_id($change->{old});
        $recipients{$uid}->{+REL_QA} = BIT_DIRECT if $uid;
      }
      elsif ($change->{field_name} eq 'assigned_to') {
        my $uid = login_to_id($change->{old});
        $recipients{$uid}->{+REL_ASSIGNEE} = BIT_DIRECT if $uid;
      }
    }
  }

  # Make sure %user_cache has every user in it so far referenced
  foreach my $user_id (keys %recipients) {
    $user_cache{$user_id} ||= new Bugzilla::User({id => $user_id, cache => 1});
  }

  Bugzilla::Hook::process(
    'bugmail_recipients',
    {
      bug        => $bug,
      recipients => \%recipients,
      users      => \%user_cache,
      diffs      => \@diffs
    }
  );

  if (scalar keys %recipients) {

    # Find all those user-watching anyone on the current list, who is not
    # on it already themselves.
    my $involved = join(",", keys %recipients);

    my $userwatchers = $dbh->selectall_arrayref(
      "SELECT watcher, watched FROM watch
                                    WHERE watched IN ($involved)"
    );

    # Mark these people as having the role of the person they are watching
    foreach my $watch (@$userwatchers) {
      while (my ($role, $bits) = each %{$recipients{$watch->[1]}}) {
        $recipients{$watch->[0]}->{$role} |= BIT_WATCHING if $bits & BIT_DIRECT;
      }
      push(@{$watching{$watch->[0]}}, $watch->[1]);
    }
  }

  # Global watcher
  my @watchers = split(/\s*,\s*/ms, Bugzilla->params->{'globalwatchers'});
  foreach (@watchers) {
    my $watcher_id = login_to_id($_);
    next unless $watcher_id;
    $recipients{$watcher_id}->{+REL_GLOBAL_WATCHER} = BIT_DIRECT;
  }

  # We now have a complete set of all the users, and their relationships to
  # the bug in question. However, we are not necessarily going to mail them
  # all - there are preferences, permissions checks and all sorts to do yet.
  my @sent;

  # The email client will display the Date: header in the desired timezone,
  # so we can always use UTC here.
  my $date = $params->{dep_only} ? $end : $bug->delta_ts;
  $date = format_time($date, '%a, %d %b %Y %T %z', 'UTC');

  # Remove duplicate references, and convert to bug objects
  @referenced_bugs = @{Bugzilla::Bug->new_from_list([uniq @referenced_bugs])};

  foreach my $user_id (keys %recipients) {
    my %rels_which_want;
    my $user = $user_cache{$user_id}
      ||= new Bugzilla::User({id => $user_id, cache => 1});

    # Deleted users must be excluded.
    next unless $user;

    # If email notifications are disabled for this account, or the bug
    # is ignored, there is no need to do additional checks.
    next if ($user->email_disabled || $user->is_bug_ignored($id));

    if ($user->can_see_bug($id)) {

      # Go through each role the user has and see if they want mail in
      # that role.
      foreach my $relationship (keys %{$recipients{$user_id}}) {
        if ($user->wants_bug_mail(
          $bug, $relationship, $start ? \@diffs : [],
          $comments, $params->{dep_only}, $changer
        ))
        {
          $rels_which_want{$relationship} = $recipients{$user_id}->{$relationship};
        }
      }
    }

    if (scalar(%rels_which_want)) {

      # So the user exists, can see the bug, and wants mail in at least
      # one role. But do we want to send it to them?

      # We shouldn't send mail if this is a dependency mail and the
      # depending bug is not visible to the user.
      # This is to avoid leaking the summary of a confidential bug.
      my $dep_ok = 1;
      if ($params->{dep_only}) {
        $dep_ok = $user->can_see_bug($params->{blocker}->id) ? 1 : 0;
      }

      # Make sure the user isn't in the nomail list, and the dep check passed.
      # BMO: never send emails to bugs or .tld addresses.  this check needs to
      # happen after the bugmail_recipients hook.
      if ($user->email_enabled && $dep_ok && ($user->login !~ /\.(?:bugs|tld)$/)) {

        # Don't show summaries for bugs the user can't access, and
        # provide a hook for extensions such as SecureMail to filter
        # this list.
        #
        # We build an array with the short_desc as a separate item to
        # allow extensions to modify the summary without touching the
        # bug object.
        my $referenced_bugs = [];
        foreach my $ref (@{$user->visible_bugs(\@referenced_bugs)}) {
          push @$referenced_bugs,
            {bug => $ref, id => $ref->id, short_desc => $ref->short_desc,};
        }
        Bugzilla::Hook::process('bugmail_referenced_bugs',
          {updated_bug => $bug, referenced_bugs => $referenced_bugs});

        my $sent_mail = sendMail({
          to              => $user,
          bug             => $bug,
          comments        => $comments,
          date            => $date,
          changer         => $changer,
          watchers        => exists $watching{$user_id} ? $watching{$user_id} : undef,
          diffs           => \@diffs,
          rels_which_want => \%rels_which_want,
          referenced_bugs => $referenced_bugs,
          dep_only        => $params->{dep_only}
        });
        push(@sent, $user->login) if $sent_mail;
      }
    }
  }

  # When sending bugmail about a blocker being reopened or resolved,
  # we say nothing about changes in the bug being blocked, so we must
  # not update lastdiffed in this case.
  if (!$params->{dep_only}) {
    $dbh->do('UPDATE bugs SET lastdiffed = ? WHERE bug_id = ?', undef, ($end, $id));
    $bug->{lastdiffed} = $end;
  }

  return {'sent' => \@sent};
}

sub sendMail {
  my $params = shift;

  my $user            = $params->{to};
  my $bug             = $params->{bug};
  my @send_comments   = @{$params->{comments}};
  my $date            = $params->{date};
  my $changer         = $params->{changer};
  my $watchingRef     = $params->{watchers};
  my @diffs           = @{$params->{diffs}};
  my $relRef          = $params->{rels_which_want};
  my $referenced_bugs = $params->{referenced_bugs};
  my $dep_only        = $params->{dep_only};
  my $attach_id;

  # Only display changes the user is allowed see.
  my @display_diffs;

  foreach my $diff (@diffs) {
    my $add_diff = 0;

    # Only display bug ids that the user is allowed to see for certain fields
    if ($diff->{field_name} =~ /^(?:dependson|blocked|regress(?:ed_by|es))$/) {
      foreach my $field ('new', 'old') {
        next if !defined $diff->{$field};
        my @bug_ids = grep {/^\d+$/} split(/[\s,]+/, $diff->{$field});
        $diff->{$field} = join ', ', @{$user->visible_bugs(\@bug_ids)};
      }
      $add_diff = 1 if $diff->{old} || $diff->{new};
    }
    elsif ($diff->{field_name} eq 'see_also') {
      my $urlbase = Bugzilla->localconfig->urlbase;
      my $bug_link_re = qr/^\Q$urlbase\Eshow_bug\.cgi\?id=(\d+)$/;
      foreach my $field ('new', 'old') {
        my @filtered;
        foreach my $value (split /[\s,]+/, $diff->{$field}) {
          next if $value =~ /$bug_link_re/ && !$user->can_see_bug($1);
          push @filtered, $value;
        }
        $diff->{$field} = join ', ', @filtered;
      }
      $add_diff = 1 if $diff->{old} || $diff->{new};
    }
    elsif (grep { $_ eq $diff->{field_name} } TIMETRACKING_FIELDS) {
      $add_diff = 1 if $user->is_timetracker;
    }
    elsif (!$diff->{isprivate} || $user->is_insider) {
      $add_diff = 1;
    }
    push(@display_diffs, $diff) if $add_diff;
    $attach_id = $diff->{attach_id} if $diff->{attach_id};
  }

  if (!$user->is_insider) {
    @send_comments = grep { !$_->is_private } @send_comments;
  }

  if (!scalar(@display_diffs) && !scalar(@send_comments)) {

    # Whoops, no differences!
    return 0;
  }

  my (@reasons, @reasons_watch);
  while (my ($relationship, $bits) = each %{$relRef}) {
    push(@reasons,       $relationship) if ($bits & BIT_DIRECT);
    push(@reasons_watch, $relationship) if ($bits & BIT_WATCHING);
  }

  my %relationships = relationships();
  my @headerrel     = map { $relationships{$_} } @reasons;
  my @watchingrel   = map { $relationships{$_} } @reasons_watch;
  push(@headerrel,   'None') unless @headerrel;
  push(@watchingrel, 'None') unless @watchingrel;
  push @watchingrel, map { user_id_to_login($_) } @$watchingRef;

  # BMO: Use field descriptions instead of field names in header
  my @changedfields     = uniq map { $_->{field_desc} } @display_diffs;
  my @changedfieldnames = uniq map { $_->{field_name} } @display_diffs;

  # BMO: Add a field to indicate when a comment was added
  if (grep($_->type != CMT_ATTACHMENT_CREATED, @send_comments)) {
    push(@changedfields,     'Comment Created');
    push(@changedfieldnames, 'comment');
  }

  # Add attachments.created to changedfields if one or more
  # comments contain information about a new attachment
  if (grep($_->type == CMT_ATTACHMENT_CREATED, @send_comments)) {
    push(@changedfields,     'Attachment Created');
    push(@changedfieldnames, 'attachment.created');
  }

  my $bugmailtype = "changed";
  $bugmailtype = "new"         if !$bug->lastdiffed;
  $bugmailtype = "dep_changed" if $dep_only;

  my $vars = {
    date               => $date,
    to_user            => $user,
    bug                => $bug,
    attach_id          => $attach_id,
    reasons            => \@reasons,
    reasons_watch      => \@reasons_watch,
    reasonsheader      => join(" ", @headerrel),
    reasonswatchheader => join(" ", @watchingrel),
    changer            => $changer,
    diffs              => \@display_diffs,
    changedfields      => \@changedfields,
    changedfieldnames  => \@changedfieldnames,
    new_comments       => \@send_comments,
    threadingmarker => build_thread_marker($bug->id, $user->id, !$bug->lastdiffed),
    referenced_bugs => $referenced_bugs,
    bugmailtype     => $bugmailtype,
  };

  if (Bugzilla->get_param_with_override('use_mailer_queue')) {
    enqueue($vars);
  }
  else {
    MessageToMTA(_generate_bugmail($vars));
  }

  return 1;
}

sub enqueue {
  my ($vars) = @_;

  # BMO: allow modification of the email at the time it was generated
  Bugzilla::Hook::process('bugmail_enqueue', {vars => $vars});

  # we need to flatten all objects to a hash before pushing to the job queue.
  # the hashes need to be inflated in the dequeue method.
  $vars->{bug}          = _flatten_object($vars->{bug});
  $vars->{to_user}      = _flatten_object($vars->{to_user});
  $vars->{changer}      = _flatten_object($vars->{changer});
  $vars->{new_comments} = [map { _flatten_object($_) } @{$vars->{new_comments}}];
  foreach my $diff (@{$vars->{diffs}}) {
    $diff->{who} = _flatten_object($diff->{who});
    if (exists $diff->{blocker}) {
      $diff->{blocker} = _flatten_object($diff->{blocker});
    }
  }
  foreach my $reference (@{$vars->{referenced_bugs}}) {
    $reference->{bug} = _flatten_object($reference->{bug});
  }
  Bugzilla->job_queue->insert('bug_mail', {vars => $vars});
}

sub dequeue {
  my ($payload) = @_;

  # clone the payload so we can modify it without impacting TheSchwartz's
  # ability to process the job when we've finished
  my $vars = dclone($payload);

  # inflate objects
  $vars->{bug}     = Bugzilla::Bug->new_from_hash($vars->{bug});
  $vars->{to_user} = Bugzilla::User->new_from_hash($vars->{to_user});
  $vars->{changer} = Bugzilla::User->new_from_hash($vars->{changer});
  $vars->{new_comments}
    = [map { Bugzilla::Comment->new_from_hash($_) } @{$vars->{new_comments}}];
  foreach my $diff (@{$vars->{diffs}}) {
    $diff->{who} = Bugzilla::User->new_from_hash($diff->{who});
    if (exists $diff->{blocker}) {
      $diff->{blocker} = Bugzilla::Bug->new_from_hash($diff->{blocker});
    }
  }

  # generate bugmail and send
  MessageToMTA(_generate_bugmail($vars), 1);
}

sub _flatten_object {
  my ($object) = @_;

  # nothing to do if it's already flattened
  return $object unless blessed($object);

  # the same objects are used for each recipient, so cache the flattened hash
  my $cache = Bugzilla->request_cache->{bugmail_flat_objects} ||= {};
  my $key = blessed($object) . '-' . $object->id;
  return $cache->{$key} ||= $object->flatten_to_hash;
}

sub _generate_bugmail {
  my ($vars)   = @_;
  my $user     = $vars->{to_user};
  my $template = Bugzilla->template_inner($user->setting('lang'));
  my ($msg_text, $msg_html, $msg_header);

  $template->process("email/bugmail-header.txt.tmpl", $vars, \$msg_header)
    || ThrowTemplateError($template->error());

  $template->process("email/bugmail.txt.tmpl", $vars, \$msg_text)
    || ThrowTemplateError($template->error());

  my @parts = (Email::MIME->create(
    attributes => {content_type => "text/plain",},
    body       => $msg_text,
  ));
  if ($user->setting('email_format') eq 'html') {
    $template->process("email/bugmail.html.tmpl", $vars, \$msg_html)
      || ThrowTemplateError($template->error());
    push @parts,
      Email::MIME->create(
      attributes => {content_type => "text/html",},
      body       => $msg_html,
      );
  }

  # TT trims the trailing newline, and threadingmarker may be ignored.
  my $email = new Email::MIME("$msg_header\n");

  # For tracking/diagnostic purposes, add our hostname
  $email->header_set('X-Generated-By' => hostname());

  if (scalar(@parts) == 1) {
    $email->content_type_set($parts[0]->content_type);
  }
  else {
    $email->content_type_set('multipart/alternative');
  }
  $email->parts_set(\@parts);

  # BMO: allow modification of the email given the enqueued variables
  Bugzilla::Hook::process('bugmail_generate', {vars => $vars, email => $email});

  return $email;
}

sub _get_diffs {
  my ($bug, $end, $user_cache) = @_;
  my $dbh = Bugzilla->dbh;

  my @args = ($bug->id);

  # If lastdiffed is NULL, then we don't limit the search on time.
  my $when_restriction = '';
  if ($bug->lastdiffed) {
    $when_restriction = ' AND bug_when > ? AND bug_when <= ?';
    push @args, ($bug->lastdiffed, $end);
  }

  my $diffs = $dbh->selectall_arrayref(
    "SELECT fielddefs.name AS field_name,
                   fielddefs.description AS field_desc,
                   bugs_activity.bug_when, bugs_activity.removed AS old,
                   bugs_activity.added AS new, bugs_activity.attach_id,
                   bugs_activity.comment_id, bugs_activity.who
              FROM bugs_activity
        INNER JOIN fielddefs
                ON fielddefs.id = bugs_activity.fieldid
             WHERE bugs_activity.bug_id = ?
                   $when_restriction
          ORDER BY bugs_activity.bug_when, fielddefs.description", {Slice => {}},
    @args
  );
  my $referenced_bugs = [];

  foreach my $diff (@$diffs) {
    $user_cache->{$diff->{who}}
      ||= new Bugzilla::User({id => $diff->{who}, cache => 1});
    $diff->{who} = $user_cache->{$diff->{who}};
    if ($diff->{attach_id}) {
      $diff->{isprivate}
        = $dbh->selectrow_array(
        'SELECT isprivate FROM attachments WHERE attach_id = ?',
        undef, $diff->{attach_id});
    }
    if ($diff->{field_name} eq 'longdescs.isprivate') {
      my $comment = Bugzilla::Comment->new($diff->{comment_id});
      $diff->{num}       = $comment->count;
      $diff->{isprivate} = $diff->{new};
    }
    elsif ($diff->{field_name} =~ /^(?:dependson|blocked|regress(?:ed_by|es))$/) {
      push @$referenced_bugs, grep {/^\d+$/} split(/[\s,]+/, $diff->{old});
      push @$referenced_bugs, grep {/^\d+$/} split(/[\s,]+/, $diff->{new});
    }
    elsif ($diff->{field_name} eq 'see_also') {
      foreach my $field ('new', 'old') {
        push @$referenced_bugs, _parse_see_also(split(/[\s,]+/, $diff->{$field}));
      }
    }
  }

  return ($diffs, $referenced_bugs);
}

sub _get_new_bugmail_fields {
  my $bug = shift;
  my @fields = @{Bugzilla->fields({obsolete => 0, in_new_bugmail => 1})};
  my @diffs;

  # Show fields in the same order as the DEFAULT_FIELDS list, which mirrors
  # 4.0's behavior and provides sane grouping of similar fields.
  # Any additional fields are sorted by description
  my @prepend;
  foreach my $name (map { $_->{name} } Bugzilla::Field::DEFAULT_FIELDS) {
    my $idx = firstidx { $_->name eq $name } @fields;
    if ($idx != -1) {
      push(@prepend, $fields[$idx]);
      splice(@fields, $idx, 1);
    }
  }
  @fields = sort { $a->description cmp $b->description } @fields;
  @fields = (@prepend, @fields);

  foreach my $field (@fields) {
    my $name  = $field->name;
    my $value = $bug->$name;

    if (ref $value eq 'ARRAY') {
      my @new_values;
      foreach my $item (@$value) {
        if (blessed($item) && $item->isa('Bugzilla::User')) {
          push(@new_values, $item->login);
        }
        else {
          push(@new_values, $item);
        }
      }
      $value = join(', ', @new_values);
    }
    elsif (blessed($value) && $value->isa('Bugzilla::User')) {
      $value = $value->login;
    }
    elsif (blessed($value) && $value->isa('Bugzilla::Object')) {
      $value = $value->name;
    }
    elsif ($name eq 'estimated_time') {

      # "0.00" (which is what we get from the DB) is true,
      # so we explicitly do a numerical comparison with 0.
      $value = 0 if $value == 0;
    }
    elsif ($name eq 'deadline') {
      $value = time2str("%Y-%m-%d", str2time($value)) if $value;
    }

    # If there isn't anything to show, don't include this header.
    next unless $value;

    push(@diffs,
      {field_name => $name, field_desc => $field->description, new => $value});
  }

  return @diffs;
}

sub _parse_see_also {
  my (@links) = @_;
  my $urlbase = Bugzilla->localconfig->urlbase;
  my $bug_link_re = qr/^\Q$urlbase\Eshow_bug\.cgi\?id=(\d+)$/;

  return grep { /^\d+$/ } map { /$bug_link_re/ ? int($1) : () } @links;
}

1;
