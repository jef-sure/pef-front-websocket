package PEF::Front::WebSocket;
use AnyEvent;
use Coro;
use Coro::AnyEvent;
use AnyEvent::Handle;
use Protocol::WebSocket::Handshake::Server;
use PEF::Front v0.09;
use PEF::Front::Route;
use PEF::Front::Config;
use PEF::Front::Response;
use PEF::Front::NLS;
use PEF::Front::WebSocket::Interface;
use Errno;

use warnings;
use strict;

our $VERSION = "0.01";
use Data::Dumper;

sub handler {
	my ($request, $context) = @_;
	my $mrf = $context->{method};
	$mrf =~ s/ ([[:lower:]])/\u$1/g;
	$mrf = ucfirst($mrf);
	my $class = cfg_app_namespace . "WebSocket::$mrf";
	my $websocket;
	eval {
		no strict 'refs';

		if (not %{$class . "::"}) {
			eval "use $class";
			die {
				result      => 'INTERR',
				answer      => 'Websocket class loading error: $1',
				answer_args => $@
			} if $@;
			if (not %{$class . "::"}) {
				die {
					result      => 'INTERR',
					answer      => 'Websocket class loading error: $1',
					answer_args => 'wrong class name'
				};
			}
		}
		$websocket = prepare_websocket($class, $request);
	};
	if ($@) {
		my $response = $@;
		$response = {answer => $@} if not ref $response;
		my $http_response = PEF::Front::Response->new(request => $request, status => 500);
		my $args = [];
		$args = $response->{answer_args}
			if exists $response->{answer_args} and 'ARRAY' eq ref $response->{answer_args};
		$response->{answer} = msg_get($context->{lang}, $response->{answer}, @$args)->{message};
		$http_response->set_body($response->{answer});
		cfg_log_level_error
			&& $request->logger->({level => "error", message => "websocket error: $response->{answer}"});
		return $http_response->response();
	}
	async {
		setup_websocket($websocket);
	};
	cede;
	return [];
}

my $websocket_heartbeat_period = 30;

BEGIN {
	PEF::Front::Route::add_prefix_handler('ws', \&handler);
	no strict 'refs';
	no warnings 'once';
	if (*PEF::Front::Config::cfg_websocket_heartbeat_period{CODE}) {
		$websocket_heartbeat_period = PEF::Front::Config::cfg_websocket_heartbeat_period();
	}
}

sub prepare_websocket {
	my ($class, $request) = @_;
	my $fh = $request->env->{'psgix.io'} or die {
		result => 'INTERR',
		answer => "Server doesn't support raw IO"
	};
	my $hs = Protocol::WebSocket::Handshake::Server->new_from_psgi($request->env);
	$hs->parse($fh) or die {
		result => 'INTERR',
		answer => 'Websocket protocol handshake error'
	};
	if (not $class->isa('PEF::Front::WebSocket::Interface')) {
		no strict 'refs';
		unshift @{$class . "::ISA"}, 'PEF::Front::WebSocket::Interface';
	}
	my $ws = bless {
		handle  => AnyEvent::Handle->new(fh => $fh),
		request => $request
	}, $class;
	my $frame = Protocol::WebSocket::Frame->new;
	$ws->{handle}->push_write($hs->to_string);
	$ws->{handle}->on_drain(
		sub {
			$ws->{handle}->on_drain(
				sub {
					$ws->on_drain if delete $ws->{expected_drain};
				}
			);
			$ws->on_open;
		}
	);
	$ws;
}

sub setup_websocket {
	my $ws       = $_[0];
	my $frame    = Protocol::WebSocket::Frame->new;
	my $on_error = sub {
		$ws->{error} = 1;
		$ws->on_error;
	};
	$ws->{handle}->on_eof($on_error);
	$ws->{handle}->on_error($on_error);
	$ws->{handle}->on_timeout(sub { });
	$ws->{handle}->on_read(
		sub {
			$frame->append($_[0]->rbuf);
			my $message = $frame->next_bytes;
			if ($frame->is_close) {
				$ws->close;
				return;
			}
			if ($frame->is_ping) {
				$ws->{handle}->push_write(
					Protocol::WebSocket::Frame->new(
						type   => 'pong',
						buffer => $message
					)->to_bytes
				);
				return;
			}
			if ($message && $frame->fin && ($frame->is_binary || $frame->is_text)) {
				my $type = 'binary';
				if ($frame->is_text) {
					utf8::decode($message);
					$type = 'text';
				}
				$ws->on_message($message, $type);
				$message = '';
			}
		}
	);
	$ws->{heartbeat} = AnyEvent->timer(
		interval => $websocket_heartbeat_period,
		cb       => sub {
			if ($ws->{handle} && !$ws->is_defunct) {
				$ws->{handle}->push_write(
					Protocol::WebSocket::Frame->new(
						type   => 'ping',
						buffer => 'ping'
					)->to_bytes
				);
			}
		}
	);
	$ws;
}

1;

__END__

=head1 NAME
 
PEF::Front::WebSocket - WebSocket framework for PEF::Front
 
=head1 SYNOPSIS

    # startup.pl
    use PEF::Front::Websocket;
    # usual startup stuff...

    # $PROJECT_DIR/app/WSTest/WebSocket/Echo.pm
    package WSTest::WebSocket::Echo;
    
    sub on_message {
        my ($self, $message) = @_;
        $self->send($message); 
    }

    1;

=head1 DESCRIPTION
 
This module makes WebSockets really easy. Every kind of WebSocket 
is in its own module. Default routing scheme is C</ws$WebSocketClass>.
WebSocket handlers are located in C<$PROJECT_DIR/app/$MyAPP/WebSocket>.
 
=head2 Prerequisites
 
This module requires L<Coro>, L<AnyEvent> and L<PSGI> server that must 
meet the following requirements.
 
=over
 
=item *
 
C<psgi.streaming> environment is true.
 
=item *
 
C<psgi.nonblocking> environment is true.
 
=item *
 
C<psgix.io> environment holds a valid raw IO socket object. See L<PSGI::Extensions>.
 
=back

L<uwsgi|https://uwsgi-docs.readthedocs.io/en/latest/PSGIquickstart.html> 
version 2.0.14+ meets all of them with C<psgi-enable-psgix-io = true>.
 
=head1 WEBSOCKET EVENT METHODS
 
=head2 on_message($message, $type)

A subroutine that is called on new message from client.

=head2 on_drain()
 
A subroutine that is called when there's nothing to send to 
client after some successful send.

=head2 on_open()

A subroutine that is called each time it establishes a new
WebSocket connection to a client.

=head2 on_error()

A subroutine that is called when some error
happens while processing a request.

=head2 on_close()
 
A subroutine that is called on WebSocket close event.
 
=head1 INHERITED METHODS

Every WebSocket class is derived from C<PEF::Front::Websocket::Interface>
which is derived from C<PEF::Front::Websocket::Base>. Even when you don't
derive your class from C<PEF::Front::Websocket::Interface> explicitly, 
this class will be added automatically to hierarchy.

=head2 send($buffer[, $type])

Sends $buffer to client. By default $type is 'text'.

=head2 close()

Closes WebSocket.

=head2 is_defunct()

Returns true when socket is closed or there's some error on it.

=head1 EXAMPLE

  #startup.pl
  use WSTest::AppFrontConfig;
  use PEF::Front::Config;
  use PEF::Front::WebSocket;
  use PEF::Front::Route;

  PEF::Front::Route::add_route(
    get '/' => '/appWs',
  );
  PEF::Front::Route->to_app();
  
  
  # $PROJECT_DIR/app/WSTest/WebSocket/Echo.pm
  package WSTest::WebSocket::Echo;
 
  sub on_message {
      my ($self, $message) = @_;
      $self->send($message); 
  }

  1;
  
  # $PROJECT_DIR/templates/ws.html
  <html>
  <head>
  <script language="Javascript">
    var s = new WebSocket("ws://[% hostname %]:[% request.port %]/wsEcho");
    s.onopen = function() {
        alert("connected !!!");
        s.send("ciao");
    };
    s.onmessage = function(e) {
        var bb = document.getElementById('blackboard')
        var html = bb.innerHTML;
        bb.innerHTML = html + '<br/>' + e.data;
    };
    s.onerror = function(e) {
        alert(e);
    }
    s.onclose = function(e) {
        alert("connection closed");
    }
    function invia() {
        var value = document.getElementById('testo').value;
        s.send(value);
    }
  </script>
  </head>
  <body>
    <h1>WebSocket</h1>
    <input type="text" id="testo" />
    <input type="button" value="invia" onClick="invia();" />
    <div id="blackboard"
        style="width: 640px; height: 480px; background-color: black; color: white; border: solid 2px red; overflow: auto">
    </div>
  </body>
  </html>
  
  # wstest.ini
  [uwsgi]
  plugins = coroae
  chdir = /$PROJECT_DIR
  logger = file:log/demo.log
  psgi = bin/startup.pl
  master = true
  processes = 4
  coroae = 1000
  perl-no-plack = true
  psgi-enable-psgix-io = true
  uid = $PROJECT_USER
  gid = www-data
  chmod-socket = 664


=head1 AUTHOR
 
This module was written and is maintained by Anton Petrusevich.

=head1 Copyright and License
 
Copyright (c) 2016 Anton Petrusevich. Some Rights Reserved.
 
This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
 
