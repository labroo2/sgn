package CXGN::Pedigree::ParseUpload::Plugin::AdditionalInfoExcel;

use Moose::Role;
use Spreadsheet::ParseExcel;
use CXGN::Stock::StockLookup;
use SGN::Model::Cvterm;
use Data::Dumper;
use CXGN::List::Validate;

sub _validate_with_plugin {
    my $self = shift;
    my $filename = $self->get_filename();
    my $schema = $self->get_chado_schema();
    my $cross_additional_info_ref = $self->get_cross_additional_info();
    my @error_messages;
    my %errors;
    my $parser = Spreadsheet::ParseExcel->new();
    my $excel_obj;
    my $worksheet;

    #try to open the excel file and report any errors
    $excel_obj = $parser->parse($filename);
    if (!$excel_obj){
        push @error_messages, $parser->error();
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    $worksheet = ($excel_obj->worksheets())[0]; #support only one worksheet
    if (!$worksheet){
        push @error_messages, "Spreadsheet must be on 1st tab in Excel (.xls) file";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    my ($row_min, $row_max) = $worksheet->row_range();
    my ($col_min, $col_max) = $worksheet->col_range();
    if (($col_max - $col_min)  < 1 || ($row_max - $row_min) < 1 ) { #must have header and at least one row of parental info
        push @error_messages, "Spreadsheet is missing header or no parental info data";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    #get column headers
    my $cross_name_head;

    if ($worksheet->get_cell(0,0)) {
        $cross_name_head  = $worksheet->get_cell(0,0)->value();
    }

    if (!$cross_name_head || $cross_name_head ne 'cross_unique_id' ) {
        push @error_messages, "Cell A1: cross_unique_id is missing from the header";
    }

    my %valid_headers;
    my @additional_info_headers = @{$cross_additional_info_ref};
    foreach my $info_field(@additional_info_headers){
        $valid_headers{$info_field} = 1;
    }

    for my $column (1 .. $col_max){
        my $header_string = $worksheet->get_cell(0,$column)->value();

        if (!$valid_headers{$header_string}){
            push @error_messages, "Invalid info type: $header_string";
        }
    }

    my %seen_cross_names;

    for my $row (1 .. $row_max){
        my $row_name = $row+1;
        my $cross_name;

        if ($worksheet->get_cell($row,0)) {
            $cross_name = $worksheet->get_cell($row,0)->value();
        }

        if (!$cross_name || $cross_name eq '') {
            push @error_messages, "Cell A$row_name: cross unique id missing";
        } elsif ($seen_cross_names{$cross_name}) {
            push @error_messages, "Duplicate cross unique id at cell A$row_name".": $cross_name";
        } else {
            $cross_name =~ s/^\s+|\s+$//g;
            $seen_cross_names{$cross_name}++;
        }

    }

    my @crosses = keys %seen_cross_names;
    my $cross_validator = CXGN::List::Validate->new();
    my @crosses_missing = @{$cross_validator->validate($schema,'crosses',\@crosses)->{'missing'}};

    if (scalar(@crosses_missing) > 0){
        push @error_messages, "The following cross unique ids are not in the database as uniquenames or synonyms: ".join(',',@crosses_missing);
        $errors{'missing_crosses'} = \@crosses_missing;
    }

    #store any errors found in the parsed file to parse_errors accessor
    if (scalar(@error_messages) >= 1) {
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    return 1; #returns true if validation is passed

}

sub _parse_with_plugin {
    my $self = shift;
    my $filename = $self->get_filename();
    my $schema = $self->get_chado_schema();
    my $parser   = Spreadsheet::ParseExcel->new();
    my $excel_obj;
    my $worksheet;
    my %parsed_result;

    $excel_obj = $parser->parse($filename);
    if (!$excel_obj){
        return;
    }

    $worksheet = ($excel_obj->worksheets())[0];
    my ($row_min, $row_max) = $worksheet->row_range();
    my ($col_min, $col_max) = $worksheet->col_range();

    for my $row (1 .. $row_max){
        my $cross_name;

        if ($worksheet->get_cell($row,0)){
            $cross_name = $worksheet->get_cell($row,0)->value();
            $cross_name =~ s/^\s+|\s+$//g;
        }

        #skip blank lines or lines with no name, type and parent
        if (!$cross_name) {
            next;
        }

        for my $column ( 1 .. $col_max ) {
            if ($worksheet->get_cell($row,$column)) {
                my $info_header =  $worksheet->get_cell(0,$column)->value();
                $info_header =~ s/^\s+|\s+$//g;
                $parsed_result{$cross_name}{$info_header} = $worksheet->get_cell($row,$column)->value();
            }
        }

    }

    print STDERR "ADDITIONAL INFO PARSED RESULT =".Dumper(\%parsed_result)."\n";

    $self->_set_parsed_data(\%parsed_result);

    return 1;
}

1;
