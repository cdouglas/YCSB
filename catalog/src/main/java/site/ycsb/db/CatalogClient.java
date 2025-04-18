package site.ycsb.db;

import org.apache.commons.lang3.RandomStringUtils;
import org.apache.iceberg.DataFile;
import org.apache.iceberg.DataFiles;
import org.apache.iceberg.PartitionSpec;
import org.apache.iceberg.Schema;
import org.apache.iceberg.catalog.Catalog;
import org.apache.iceberg.catalog.CatalogTransaction;
import org.apache.iceberg.catalog.Namespace;
import org.apache.iceberg.catalog.SupportsCatalogTransactions;
import org.apache.iceberg.catalog.TableIdentifier;
import org.apache.iceberg.exceptions.AlreadyExistsException;
import org.apache.iceberg.exceptions.CommitFailedException;
import org.apache.iceberg.exceptions.ValidationException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import site.ycsb.ByteIterator;
import site.ycsb.DB;
import site.ycsb.DBException;
import site.ycsb.Status;
import site.ycsb.generator.ExponentialGenerator;
import site.ycsb.generator.ZipfianGenerator;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.Vector;
import java.util.concurrent.locks.ReentrantLock;

import static java.lang.Math.max;
import static java.lang.Math.min;
import static org.apache.iceberg.types.Types.IntegerType;
import static org.apache.iceberg.types.Types.NestedField.required;
import static org.apache.iceberg.types.Types.StringType;

public abstract class CatalogClient <C extends Catalog> extends DB {

  private static final Logger LOG = LoggerFactory.getLogger(CatalogClient.class);

  protected final static ReentrantLock initLock = new ReentrantLock();
  protected static boolean catalogInited = false;

  protected C catalog;

  private final int NUM_TABLES = 20;
  private final int MAX_TABLES_PER_TX = 8;

  private final ZipfianGenerator zGen = new ZipfianGenerator(NUM_TABLES);
  private final ExponentialGenerator eGen = new ExponentialGenerator(1.6);

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

  static final String YCSB_BUCKET = "lst-consistency/YCSB";
  static final String UNIQ_RUN = RandomStringUtils.randomAlphanumeric(8);
  protected static final CatalogTransaction.IsolationLevel SSI = CatalogTransaction.IsolationLevel.SERIALIZABLE;

  boolean isMultiTable = false;

  private Optional<TableIdentifier> getIdentifierFromTableName(String tableName){
    return catalog.listTables(Namespace.empty()).stream()
        .filter(identifier -> identifier.name().equals(tableName))
        .findAny();
  }

  private String genTableName(){
    return zGen.nextValue().toString();
  }

  private List<TableIdentifier> getTxTables(){
    int tablesToUse =  min(max(1, eGen.nextValue().intValue()), MAX_TABLES_PER_TX);
    HashSet<TableIdentifier> tables = new HashSet<>();
    while (tables.size() < tablesToUse) {
      tables.add(TableIdentifier.of(Namespace.empty(), genTableName()));
    }
    return new ArrayList<>(tables);
  }

  protected synchronized void initTables() {
    if (catalogInited) {
      LOG.info("Catalog already initialized");
      return;
    }
    for (int i = 0; i < NUM_TABLES; i++) {
      TableIdentifier identifier = TableIdentifier.of(Namespace.empty(), Integer.toString(i));
      try {Thread.sleep(100);} catch (Exception ignored){};
      if(!catalog.tableExists(identifier)){
        LOG.info("Init table: " + identifier);
        catalog.createTable(identifier, SCHEMA, SPEC);
      }
    }
    catalogInited = true;
  }

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
                              Vector<HashMap<String, ByteIterator>> result) {
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

    String txId = RandomStringUtils.randomAlphanumeric(8);
    var tablesUtilized = getTxTables();
    int attempts = 0;

    System.out.println(txId + ") Tables Involved: " + (isMultiTable ?  tablesUtilized.toString() : "[default]"));

      while (true) {
        try {
          if (isMultiTable) {
            CatalogTransaction catalogTransaction = ((SupportsCatalogTransactions) catalog).createTransaction(SSI);
            Catalog txCatalog = catalogTransaction.asCatalog();
            for (TableIdentifier t : tablesUtilized) {
              txCatalog.loadTable(t).newFastAppend().appendFile(FILE_A);
            }
            catalogTransaction.commitTransaction();
          } else {
            var tid = TableIdentifier.of(Namespace.empty(), key);
            var tx = catalog.buildTable(tid, SCHEMA).createOrReplaceTransaction();
            values.forEach((k, v) -> tx.updateProperties().set(k, v.toString()));
            tx.commitTransaction();
          }

          System.out.println(txId + ") Committed");

          return Status.OK;

        } catch (CommitFailedException e){
          System.out.println(txId + ") Retrying TX (CAS)");
        } catch (ValidationException e){
          System.out.println(txId + ") Retrying TX (SSI Validation): "  + tablesUtilized.toString());
        } catch (java.io.UncheckedIOException e){
          System.out.println(txId + ") Retrying TX (Catalog Not Found?): "  + tablesUtilized.toString());
        } catch (com.google.cloud.storage.StorageException e){
          System.out.println(txId + ") Retrying TX (Rate Limited)");
        }

        //Full-jitter backoff
        double temperature = 400 * Math.pow(2, attempts);
        double fullJitterSleep =  Math.random() * temperature; // E[sleep] = 200*2^a
        try {
          Thread.sleep((long) fullJitterSleep);
        } catch (Exception ignored){};
        attempts += 1;
      }

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
    // We don't seem to be using this in the benchmark...?
    if (isMultiTable)
      return Status.NOT_IMPLEMENTED;

    String txId = RandomStringUtils.randomAlphanumeric(8);
    var tid = TableIdentifier.of(Namespace.empty(), key);
    int attempts = 0;

    System.out.println(txId + ") Adding Table: " );

    while(true) {
      try {

        catalog.newCreateTableTransaction(tid, SCHEMA).commitTransaction();
        // catalog.createTable(tid, SCHEMA);
        return Status.OK;

      } catch (AlreadyExistsException e){
        return Status.BAD_REQUEST;
      } catch (CommitFailedException e){
        System.out.println(txId + ") Retrying TX (CAS)");
      } catch (java.io.UncheckedIOException e){
        System.out.println(txId + ") Retrying TX (Catalog Not Found?)");
      } catch (com.google.cloud.storage.StorageException e){
        System.out.println(txId + ") Retrying TX (Rate Limited)");
      }

      //Full-jitter backoff
      double temperature = 400 * Math.pow(2, attempts);
      double fullJitterSleep =  Math.random() * temperature; // E[sleep] = 200*2^a
      try{Thread.sleep((long) fullJitterSleep);} catch (Exception ignored){};
      attempts += 1;
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
  public Status delete(String table, String key) {
    return Status.NOT_IMPLEMENTED;
    // I don't really know what we want down here now. Are we even using deletes...?
//    String txId = RandomStringUtils.randomAlphanumeric(8);
//    Optional<TableIdentifier> tblIdentifier = getIdentifierFromTableName(table);
//    if (tblIdentifier.isEmpty()) {
//      return Status.BAD_REQUEST;
//    }
//    int attempts = 0;
//
//    System.out.println(txId + ") Adding Table: " );
//
//    while(true) {
//      try {
//
//        if (catalog.dropTable(tblIdentifier.get())) {
//          return Status.OK;
//        }
//
//      } catch (com.google.cloud.storage.StorageException e){
//        System.out.println(txId + ") Retrying TX (Rate Limited)");
//      }
//
//      //Full-jitter backoff
//      double temperature = 400 * Math.pow(2, attempts);
//      double fullJitterSleep =  Math.random() * temperature; // E[sleep] = 200*2^a
//      try{Thread.sleep((long) fullJitterSleep);} catch (Exception ignored){};
//      attempts += 1;
//    }
  }

}