# Module test errors

## False negative (can force)

- Net::SSLeay (OpenSSL3 api changes, probably safe) 
- IO::Socket::SSL (OpenSSL3 api changes, probably safe)
- File::Rsync (rsync not installed)


## Probably not needed

- Data::Swap
- Set::IntSpan::Fast::XS
- Mojolicious::Plugin::YamlConfig

## Special cases

- Spreadsheet::XLSX : Error on "OLE::Storage_Lite", probably safe

## Indirect

- XML::Compile (Data::Parse)
- SOAP::Data::ComplexType (Net::SSLeay)

## TODO

MailTools
Mojolicious::Plugin::Status
Spreadsheet::ParseXLSX
OLE::Storage_Lite
Filesys::SmbClientParser
SOAP::Lite
JSON::Validator
String::Print
Log::Report::Optional
DBD::Oracle
Mojolicious::Plugin::WriteExcel
CHI
Minion::Backend::SQLite
Sereal
Mojolicious::Plugin::CHI
Net::SMTP::TLS
String::Diff
Spreadsheet::WriteExcel::Simple
Sereal::Encoder
RT::Client::REST
JIRA::REST
XML::Compile::Tester
Mojolicious::Plugin::OpenAPI
Search::Elasticsearch
Date::Parse
Spreadsheet::WriteExcel
MIME::Lite
MIME::Tools
Plack::Middleware::ServerStatus::Lite
XML::Compile::SOAP
XML::Compile::Cache
Log::Report
DateTime::Format::DateParse
REST::Client
Spreadsheet::ParseExcel
SOAP::Data::Builder
Mojo::SQLite
LWP::Protocol::https