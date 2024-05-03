package site.ycsb.db;

import com.google.cloud.storage.Storage;
import org.apache.commons.lang3.RandomStringUtils;
import org.apache.iceberg.*;
import org.apache.iceberg.catalog.*;
import org.apache.iceberg.exceptions.AlreadyExistsException;
import org.apache.iceberg.exceptions.CommitFailedException;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.generator.ExponentialGenerator;
import site.ycsb.generator.ZipfianGenerator;

import java.io.File;
import java.util.*;

import static java.lang.Math.PI;
import static java.lang.Math.max;
import static org.apache.iceberg.types.Types.NestedField.required;
import static org.apache.iceberg.types.Types.*;

public abstract class CatalogClient <
    C extends SupportsCatalogTransactions & SupportsNamespaces & Catalog> extends DB {

  protected Catalog catalog;
  protected Storage storage;

  static final Schema SCHEMA =
      new Schema(
          required(1, "id", IntegerType.get(), "unique ID"),
          required(2, "data", StringType.get()));

  protected static final PartitionSpec SPEC =
      PartitionSpec.builderFor(SCHEMA).bucket("data", 16).build();


  protected static final DataFile FILE_A =
      DataFiles.builder(SPEC)
          .withPath("/path/to/data-a.parquet")
          .withFileSizeInBytes(10)
          .withPartitionPath("data_bucket=0") // easy way to set partition data for now
          .withRecordCount(1)
          .build();
  protected static final DataFile FILE_B =
      DataFiles.builder(SPEC)
          .withPath("/path/to/data-b.parquet")
          .withFileSizeInBytes(10)
          .withPartitionPath("data_bucket=1") // easy way to set partition data for now
          .withRecordCount(1)
          .build();
  protected static final DataFile FILE_C =
      DataFiles.builder(SPEC)
          .withPath("/path/to/data-c.parquet")
          .withFileSizeInBytes(10)
          .withPartitionPath("data_bucket=2") // easy way to set partition data for now
          .withRecordCount(1)
          .build();
  protected static final DataFile FILE_D =
      DataFiles.builder(SPEC)
          .withPath("/path/to/data-d.parquet")
          .withFileSizeInBytes(10)
          .withPartitionPath("data_bucket=3") // easy way to set partition data for now
          .withRecordCount(1)
          .build();

  final File credentials() {
    // https://cloud.google.com/docs/authentication/provide-credentials-adc#local-dev
    String location = System.getenv("GOOGLE_APPLICATION_CREDENTIALS");
    if (null == location) {
      location = getProperties().getProperty("gcp.creds");
    }
    if (null == location) {
      throw new IllegalArgumentException("Missing credential location");
    }
    return new File(location);
  }

  protected String warehouse = "gs://benchmarking-ycsb/" + RandomStringUtils.randomAlphanumeric(8);
  final String gs_location = warehouse + "/catalog";

  final CatalogTransaction.IsolationLevel SSI = CatalogTransaction.IsolationLevel.SERIALIZABLE;

  boolean  isMultiTable = true;

  private Optional<TableIdentifier> getIdentifierFromTableName(String tableName){
    return catalog.listTables(Namespace.empty()).stream()
        .filter(identifier -> identifier.name().equals(tableName))
        .findAny();
  }

  private String genTableName(){
    return  zGen.nextValue().toString();
  }

  private List<TableIdentifier> getTxTables(){

    int tablesToUse =  max(1, eGen.nextValue().intValue());

    HashSet<TableIdentifier> tables = new HashSet<>();

    while(tables.size() < tablesToUse){
      tables.add(TableIdentifier.of(Namespace.empty(), genTableName()));
    }

    return tables.stream().toList();
  }

  protected void init_all_tables(){
    for(int i = 0; i < NUM_TABLES; i++){
      TableIdentifier identifier = TableIdentifier.of(Namespace.empty(), Integer.toString(i));
      catalog.createTable(identifier, SCHEMA, SPEC);
    }
  }

  private final int NUM_TABLES = 20;
  private final ZipfianGenerator zGen = new ZipfianGenerator(NUM_TABLES);
  private final ExponentialGenerator eGen = new ExponentialGenerator(2);

  @Override
  abstract public void init() throws DBException;


  /**
   * Read a record from the database. Each field/value pair from the result will be stored in a HashMap.
   *
   * @param table The name of the table
   * @param key The record key of the record to read.
   * @param fields The list of fields to read, or null for all of them
   * @param result A HashMap of field/value pairs for the result
   * @return The result of the operation.
   */
  public Status read(String table, String key, Set<String> fields, Map<String, ByteIterator> result){
    return Status.OK;
  }

  /**
   * Perform a range scan for a set of records in the database. Each field/value pair from the result will be stored
   * in a HashMap.
   *
   * @param table The name of the table
   * @param startkey The record key of the first record to read.
   * @param recordcount The number of records to read
   * @param fields The list of fields to read, or null for all of them
   * @param result A Vector of HashMaps, where each HashMap is a set field/value pairs for one record
   * @return The result of the operation.
   */
  @Override
  public Status scan(String table, String startkey, int recordcount, Set<String> fields,
                              Vector<HashMap<String, ByteIterator>> result){
    return Status.OK;
  }

  /**
   * Update a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key, overwriting any existing values with the same field name.
   *
   * @param table The name of the table
   * @param key The record key of the record to write.
   * @param values A HashMap of field/value pairs to update in the record
   * @return The result of the operation.
   */
  @Override
  public Status update(String table, String key, Map<String, ByteIterator> values) {
    if(isMultiTable){
      // we should add retry logic here.. right?

      CatalogTransaction catalogTransaction = ((C) catalog).createTransaction(SSI);
      Catalog txCatalog = catalogTransaction.asCatalog();
      var a = getTxTables();
      System.out.println("Tables Involved: " + a.toString());
      for(TableIdentifier t : a) {
        switch (t.hashCode() % 3){
          case 0:
            txCatalog.loadTable(t).newFastAppend().appendFile(FILE_A).appendFile(FILE_B).commit();
          case 1:
            txCatalog.loadTable(t).newDelete().deleteFile(FILE_C).commit();
            txCatalog.loadTable(t).newFastAppend().appendFile(FILE_B).appendFile(FILE_C).commit();
          case 2:
            txCatalog.loadTable(t).newDelete().deleteFile(FILE_A).commit();
            txCatalog.loadTable(t).newAppend().appendFile(FILE_D).commit();
        }
      }

      catalogTransaction.commitTransaction();

    } else {
      var tid = TableIdentifier.of(Namespace.empty(), key);
      try {
        var tx = catalog.buildTable(tid, SCHEMA).createOrReplaceTransaction();
        values.forEach((k, v) -> tx.updateProperties().set(k, v.toString()));
      } catch (CommitFailedException e) {
        return Status.ERROR;
      }
    }
      return Status.OK;
  }

  /**
   * Insert a record in the database. Any field/value pairs in the specified values HashMap will be written into the
   * record with the specified record key.
   *
   * @param table The name of the table
   * @param key The record key of the record to insert.
   * @param values A HashMap of field/value pairs to insert in the record
   * @return The result of the operation.
   */
  @Override
  public Status insert(String table, String key, Map<String, ByteIterator> values){
    if(isMultiTable){
      // we assume all tables are already inserted, MTT overhead in updating metadata as simulated above
      return Status.OK;
    } else {
      var tid = TableIdentifier.of(Namespace.empty(), key);
      try {
        catalog.newCreateTableTransaction(tid, SCHEMA).commitTransaction();
      } catch (CommitFailedException e) {
        return Status.ERROR;
      } catch (AlreadyExistsException e) {
        return Status.BAD_REQUEST;
      }
      return Status.OK;
    }
  }

  /**
   * Delete a record from the database.
   *
   * @param table The name of the table
   * @param key The record key of the record to delete.
   * @return The result of the operation.
   */
  @Override
  public Status delete(String table, String key){
    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);
    if (!tblIdentifier.isPresent()) {
      return Status.BAD_REQUEST;
    }
    if (!catalog.dropTable(tblIdentifier.get())) {
      return Status.ERROR;
    }
    return Status.OK;
  }

}