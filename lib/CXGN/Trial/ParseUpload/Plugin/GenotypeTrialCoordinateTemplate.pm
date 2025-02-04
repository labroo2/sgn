package CXGN::Trial::ParseUpload::Plugin::GenotypeTrialCoordinateTemplate;

use Moose::Role;
use Text::CSV;
use CXGN::List::Validate;
use CXGN::Stock::StockLookup;
use SGN::Model::Cvterm;
use Data::Dumper;
use Scalar::Util qw(looks_like_number);

sub _validate_with_plugin {
    my $self = shift;
    my $args = shift;
    my $filename = $self->get_filename();
    my $schema = $self->get_chado_schema();

    my $delimiter = ',';
    my @error_messages;
    my %errors;

    my $genotyping_plate_id = $args->{genotyping_plate_id};

    my $csv = Text::CSV->new({ sep_char => ',' });

    open(my $fh, '<', $filename)
        or die "Could not open file '$filename' $!";

    if (!$fh) {
        push @error_messages, "Could not read file. Make sure it is a valid CSV file.";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    my $header_row = <$fh>;
    my @columns;
    if ($csv->parse($header_row)) {
        @columns = $csv->fields();
    } else {
        push @error_messages, "Could not parse header row. Make sure it is a valid CSV file.";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    my $num_cols = scalar(@columns);
    if ($num_cols != 6){
        push @error_messages, 'Header row must contain: "Value","Column","Row","Identification","Person","Date"';
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    if ( $columns[0] ne "Value" &&
        $columns[1] ne "Column" &&
        $columns[2] ne "Row" &&
        $columns[3] ne "Identification" &&
        $columns[4] ne "Person" &&
        $columns[5] ne "Date" ) {
            push @error_messages, 'File contents incorrect. Header row must contain: "Value","Column","Row","Identification","Person","Date"';
            $errors{'error_messages'} = \@error_messages;
            $self->_set_parse_errors(\%errors);
            return;
    }

    my %seen_sample_ids;
    my %seen_source_names;
    while ( my $row = <$fh> ){
        my @columns;
        if ($csv->parse($row)) {
            @columns = $csv->fields();
        } else {
            push @error_messages, "Could not parse row $row.";
            $errors{'error_messages'} = \@error_messages;
            $self->_set_parse_errors(\%errors);
            return;
        }

        if (scalar(@columns) != $num_cols){
            push @error_messages, 'All lines must have same number of columns as header! Error on row: '.$row;
            $errors{'error_messages'} = \@error_messages;
            $self->_set_parse_errors(\%errors);
            return;
        }

        if (!$columns[0] || $columns[0] eq ''){
            next;
        } else {
            my $source_name = $columns[0];
            $source_name =~ s/^\s+|\s+$//g; #trim whitespace from front and end...
            if (index($source_name, 'BLANK') != -1) {
                $source_name = 'BLANK';
            }
            if ($source_name eq 'exclude'){
                $source_name = 'BLANK';
            }
            $seen_source_names{$source_name}++;
        }
        if (!$columns[1] || $columns[1] eq ''){
            push @error_messages, 'The second column must contain a Column on row: '.$row;
        }
        if (!$columns[2] || $columns[2] eq ''){
            push @error_messages, 'The third column must contain a Row on row: '.$row;
        }
        if (!$columns[4] || $columns[4] eq ''){
            push @error_messages, 'The fifth column must contain Person on row: '.$row;
        }
        if (!$columns[5] || $columns[5] eq ''){
            push @error_messages, 'The sixth column must contain Date on row: '.$row;
        } elsif (!$columns[5] =~ m/(\d{4})-(\d{2})-(\d{2})/) {
            push @error_messages, "Date must be YYYY-MM-DD format";
        }

        $columns[1] = sprintf("%02d", $columns[1]);
        my $sample_name = $genotyping_plate_id."_".$columns[2].$columns[1];
        if ($seen_sample_ids{$sample_name}){
            push @error_messages, "Duplicate Sample Name $sample_name in your file on row: ".$row;
        }
        $seen_sample_ids{$sample_name}++;
    }

    my @sample_ids = keys %seen_sample_ids;
    my $rs = $schema->resultset("Stock::Stock")->search({
        'is_obsolete' => { '!=' => 't' },
        'uniquename' => { -in => \@sample_ids }
    });
    while (my $r=$rs->next){
        push @error_messages, "Cell A".$seen_sample_ids{$r->uniquename}.": Value already exists: ".$r->uniquename;
    }

    my $tissue_sample_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'tissue_sample', 'stock_type')->cvterm_id;
    my $plant_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'plant', 'stock_type')->cvterm_id;
    my $plot_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'plot', 'stock_type')->cvterm_id;
    my $accession_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'accession', 'stock_type')->cvterm_id;
    my @seen_source_observation_unit_names = keys %seen_source_names;
    $rs = $schema->resultset("Stock::Stock")->search({
        'is_obsolete' => { '!=' => 't' },
        'uniquename' => { -in => \@seen_source_observation_unit_names },
        'type_id' => [$tissue_sample_cvterm_id, $plant_cvterm_id, $plot_cvterm_id, $accession_cvterm_id]
    });
    my %found_source_observation_unit_names;
    while (my $r=$rs->next){
        $found_source_observation_unit_names{$r->uniquename} = 1;
    }
    foreach (@seen_source_observation_unit_names){
        if (!$found_source_observation_unit_names{$_}){
            push @error_messages, "This source observation unit name is not in the database: $_ .";
        }
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
    print STDERR "Parsing genotype trial file upload\n";
    my $self = shift;
    my $args = shift;
    my $filename = $self->get_filename();
    my $schema = $self->get_chado_schema();
    my $delimiter = ',';
    my %parse_result;
    my @error_messages;
    my %errors;

    my $genotyping_plate_id = $args->{genotyping_plate_id};

    my $csv = Text::CSV->new({ sep_char => ',' });

    open(my $fh, '<', $filename)
        or die "Could not open file '$filename' $!";

    if (!$fh) {
        push @error_messages, "Could not read file. Make sure it is a valid CSV file.";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }

    my $header_row = <$fh>;
    my @header_columns;
    if ($csv->parse($header_row)) {
        @header_columns = $csv->fields();
    } else {
        push @error_messages, "Could not parse header row. Make sure it is a valid CSV file.";
        $errors{'error_messages'} = \@error_messages;
        $self->_set_parse_errors(\%errors);
        return;
    }
    my $num_cols = scalar(@header_columns);

    my %seen_seedlot_names;
    my %design;
    while ( my $row = <$fh> ){
        my @columns;
        if ($csv->parse($row)) {
            @columns = $csv->fields();
        } else {
            push @error_messages, "Could not parse row $row.";
            $errors{'error_messages'} = \@error_messages;
            $self->_set_parse_errors(\%errors);
            return;
        }

        my $source_name = $columns[0];
        if (!$source_name || $source_name eq ''){
            next;
        }

        my $col_number = $columns[1];
        my $row_number = $columns[2];
        my $notes = $columns[3];
        my $dna_person = $columns[4];
        my $date = $columns[5];
        $source_name =~ s/^\s+|\s+$//g; #trim whitespace from front and end...
        $col_number = sprintf("%02d", $col_number);

        my $sample_id = $genotyping_plate_id."_".$row_number.$col_number;

        my $key = $row;
        if (index($source_name, 'BLANK') != -1) {
            $source_name = 'BLANK';
            $design{$key}->{is_blank} = 1;
        } elsif ($source_name eq 'exclude'){
            $source_name = 'BLANK';
            $design{$key}->{is_blank} = 1;
        } else {
            $design{$key}->{is_blank} = 0;
        }

        $col_number = sprintf( "%02d", $col_number );
        my @letters = 'A' .. 'ZZ';
        if (looks_like_number($row_number)){
            $row_number = $letters[$row_number - 1];
        }

        $design{$key}->{date} = $date;
        $design{$key}->{sample_id} = $sample_id;
        $design{$key}->{well} = $row_number.$col_number;
        $design{$key}->{row} = $row_number;
        $design{$key}->{column} = $col_number;
        $design{$key}->{source_stock_uniquename} = $source_name;
        $design{$key}->{ncbi_taxonomy_id} = 'NA';
        $design{$key}->{dna_person} = $dna_person;
        $design{$key}->{notes} = $notes;
        $design{$key}->{tissue_type} = 'leaf'; #Set to leaf by default because DaRT requires this and this info not in upload file
        $design{$key}->{extraction} = 'NA';
        $design{$key}->{concentration} = 'NA';
        $design{$key}->{volume} = 'NA';
    }

    #print STDERR Dumper \%design;
    $self->_set_parsed_data(\%design);

    return 1;
}


1;
